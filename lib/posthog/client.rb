# frozen_string_literal: true

require 'time'
require 'securerandom'

require 'posthog/defaults'
require 'posthog/logging'
require 'posthog/utils'
require 'posthog/send_worker'
require 'posthog/noop_worker'
require 'posthog/message_batch'
require 'posthog/transport'
require 'posthog/feature_flags'
require 'posthog/feature_flag_evaluations'
require 'posthog/send_feature_flags_options'
require 'posthog/exception_capture'

module PostHog
  class Client
    include PostHog::Utils
    include PostHog::Logging

    # Thread-safe tracking of client instances per API key for singleton warnings
    @instances_by_api_key = {}
    @instances_mutex = Mutex.new

    class << self
      # Resets instance tracking. Used primarily for testing.
      # In production, instance counts persist for the lifetime of the process.
      def reset_instance_tracking!
        @instances_mutex.synchronize do
          @instances_by_api_key = {}
        end
      end

      def _increment_instance_count(api_key)
        @instances_mutex.synchronize do
          count = @instances_by_api_key[api_key] || 0
          @instances_by_api_key[api_key] = count + 1
          count
        end
      end

      def _decrement_instance_count(api_key)
        @instances_mutex.synchronize do
          count = (@instances_by_api_key[api_key] || 1) - 1
          @instances_by_api_key[api_key] = [count, 0].max
        end
      end
    end

    # @param [Hash] opts
    # @option opts [String] :api_key Your project's api_key
    # @option opts [String] :personal_api_key Your personal API key
    # @option opts [FixNum] :max_queue_size Maximum number of calls to be
    #   remain queued. Defaults to 10_000.
    # @option opts [Bool] :test_mode +true+ if messages should remain
    #   queued for testing. Defaults to +false+.
    # @option opts [Bool] :sync_mode +true+ to send events synchronously
    #   on the calling thread. Useful in forking environments like Sidekiq
    #   and Resque. Defaults to +false+.
    # @option opts [Proc] :on_error Handles error calls from the API.
    # @option opts [String] :host Fully qualified hostname of the PostHog server. Defaults to `https://us.i.posthog.com`
    # @option opts [Integer] :feature_flags_polling_interval How often to poll for feature flag definition changes.
    #   Measured in seconds, defaults to 30.
    # @option opts [Integer] :feature_flag_request_timeout_seconds How long to wait for feature flag evaluation.
    #   Measured in seconds, defaults to 3.
    # @option opts [Proc] :before_send A block that receives the event hash and should return either a modified hash
    #   to be sent to PostHog or nil to prevent the event from being sent. e.g. `before_send: ->(event) { event }`
    # @option opts [Bool] :disable_singleton_warning +true+ to suppress the warning when multiple clients
    #   share the same API key. Use only when you intentionally need multiple clients. Defaults to +false+.
    # @option opts [Object] :flag_definition_cache_provider An object implementing the
    #   {FlagDefinitionCacheProvider} interface for distributed flag definition caching.
    #   EXPERIMENTAL: This API may change in future minor version bumps.
    def initialize(opts = {})
      symbolize_keys!(opts)

      opts[:api_key] = normalize_string_option(opts[:api_key])
      opts[:personal_api_key] = normalize_string_option(opts[:personal_api_key], blank_as_nil: true)
      opts[:host] = normalize_host_option(opts[:host])

      @queue = Queue.new
      @api_key = opts[:api_key]
      @max_queue_size = opts[:max_queue_size] || Defaults::Queue::MAX_SIZE
      @worker_mutex = Mutex.new
      @sync_mode = opts[:sync_mode] == true && !opts[:test_mode]
      @on_error = opts[:on_error] || proc { |status, error| }
      @worker = if opts[:test_mode]
                  NoopWorker.new(@queue)
                elsif @sync_mode
                  nil
                else
                  SendWorker.new(@queue, @api_key, opts)
                end
      if @sync_mode
        @transport = Transport.new(
          api_host: opts[:host],
          skip_ssl_verification: opts[:skip_ssl_verification],
          retries: 3
        )
        @sync_lock = Mutex.new
      end
      @worker_thread = nil
      @feature_flags_poller = nil
      @personal_api_key = opts[:personal_api_key]

      check_api_key!
      logger.error('api_key is empty after trimming whitespace; check your project API key') if @api_key == ''

      # Warn when multiple clients are created with the same API key (can cause dropped events)
      unless opts[:test_mode] || opts[:disable_singleton_warning]
        previous_count = self.class._increment_instance_count(@api_key)
        if previous_count >= 1
          logger.warn(
            'Multiple PostHog client instances detected for the same API key. ' \
            'This can cause dropped events and inconsistent behavior. ' \
            'Use a singleton pattern: instantiate once and reuse the client. ' \
            'See https://posthog.com/docs/libraries/ruby'
          )
        end
      end

      @feature_flags_poller =
        FeatureFlagsPoller.new(
          opts[:feature_flags_polling_interval],
          opts[:personal_api_key],
          @api_key,
          opts[:host],
          opts[:feature_flag_request_timeout_seconds] || Defaults::FeatureFlags::FLAG_REQUEST_TIMEOUT_SECONDS,
          opts[:on_error],
          flag_definition_cache_provider: opts[:flag_definition_cache_provider]
        )

      @distinct_id_has_sent_flag_calls = SizeLimitedHash.new(Defaults::MAX_HASH_SIZE) do |hash, key|
        hash[key] = []
      end

      @before_send = opts[:before_send]
      @deprecation_emitted_for = Concurrent::Set.new
    end

    # Synchronously waits until the worker has cleared the queue.
    #
    # Use only for scripts which are not long-running, and will specifically
    # exit
    def flush
      if @sync_mode
        # Wait for any in-flight sync send to complete
        @sync_lock.synchronize {} # rubocop:disable Lint/EmptyBlock
        return
      end

      while !@queue.empty? || @worker.is_requesting?
        ensure_worker_running
        sleep(0.1)
      end
    end

    # Clears the queue without waiting.
    #
    # Use only in test mode
    def clear
      @queue.clear
    end

    # @!macro common_attrs
    #   @option attrs [String] :message_id ID that uniquely
    #     identifies a message across the API. (optional)
    #   @option attrs [Time] :timestamp When the event occurred (optional)
    #   @option attrs [String] :distinct_id The ID for this user in your database

    # Captures an event
    #
    # @param [Hash] attrs
    #
    # @option attrs [String] :event Event name
    # @option attrs [Hash] :properties Event properties (optional)
    # @option attrs [Bool, Hash, SendFeatureFlagsOptions] :send_feature_flags
    #   Whether to send feature flags with this event, or configuration for feature flag evaluation (optional)
    # @option attrs [PostHog::FeatureFlagEvaluations] :flags A snapshot returned by
    #   {#evaluate_flags}. When present, `$feature/<key>` and `$active_feature_flags` are
    #   attached from the snapshot without making an additional /flags request, and this
    #   takes precedence over `:send_feature_flags`.
    # @option attrs [String] :uuid ID that uniquely identifies an event;
    #                             events in PostHog are deduplicated by the
    #                             combination of teamId, timestamp date,
    #                             event name, distinct id, and UUID
    # @macro common_attrs
    def capture(attrs)
      symbolize_keys! attrs

      # Precedence: an explicit `flags` snapshot always wins, regardless of
      # `send_feature_flags`. The snapshot guarantees the event carries the same
      # values the developer branched on with no additional network call.
      if attrs[:flags]
        if attrs[:flags].is_a?(FeatureFlagEvaluations)
          if attrs[:send_feature_flags]
            logger.warn(
              '[FEATURE FLAGS] Both `flags` and `send_feature_flags` were passed to ' \
              'capture(); using `flags` and ignoring `send_feature_flags`.'
            )
          end
          snapshot_props = attrs[:flags]._get_event_properties
          attrs[:properties] = snapshot_props.merge(attrs[:properties] || {})
          attrs.delete(:flags)
          attrs.delete(:send_feature_flags)
        else
          logger.warn(
            '[FEATURE FLAGS] capture(flags:) expects a PostHog::FeatureFlagEvaluations snapshot ' \
            "from `client.evaluate_flags(...)`; got #{attrs[:flags].class}. Ignoring."
          )
          attrs.delete(:flags)
        end
      end

      send_feature_flags_param = attrs[:send_feature_flags]
      if send_feature_flags_param
        _emit_deprecation(
          :capture_send_feature_flags,
          '`send_feature_flags` on `capture` is deprecated and will be removed in a future major ' \
          'version. Pass a `flags` snapshot from `client.evaluate_flags(...)` instead — it ' \
          'avoids a second `/flags` request per capture and guarantees the event carries the ' \
          'exact flag values your code branched on.'
        )
        # Handle different types of send_feature_flags parameter
        case send_feature_flags_param
        when true
          # Backward compatibility: simple boolean
          feature_variants = @feature_flags_poller.get_feature_variants(attrs[:distinct_id], attrs[:groups] || {})
        when Hash
          # Hash with options
          options = SendFeatureFlagsOptions.from_hash(send_feature_flags_param)
          feature_variants = @feature_flags_poller.get_feature_variants(
            attrs[:distinct_id],
            attrs[:groups] || {},
            options ? options.person_properties : {},
            options ? options.group_properties : {},
            options ? options.only_evaluate_locally : false
          )
        when SendFeatureFlagsOptions
          # SendFeatureFlagsOptions object
          feature_variants = @feature_flags_poller.get_feature_variants(
            attrs[:distinct_id],
            attrs[:groups] || {},
            send_feature_flags_param.person_properties,
            send_feature_flags_param.group_properties,
            send_feature_flags_param.only_evaluate_locally || false
          )
        else
          # Invalid type, treat as false
          feature_variants = nil
        end

        attrs[:feature_variants] = feature_variants if feature_variants
      end

      enqueue(FieldParser.parse_for_capture(attrs))
    end

    # Captures an exception as an event
    #
    # @param [Exception, String, Object] exception The exception to capture, a string message, or exception-like object
    # @param [String] distinct_id The ID for the user (optional, defaults to a generated UUID)
    # @param [Hash] additional_properties Additional properties to include with the exception event (optional)
    # @param [PostHog::FeatureFlagEvaluations] flags A snapshot returned by {#evaluate_flags}.
    #   Forwarded to the inner {#capture} call so the captured `$exception` event carries the
    #   same `$feature/<key>` and `$active_feature_flags` properties as the snapshot.
    def capture_exception(exception, distinct_id = nil, additional_properties = {}, flags: nil)
      exception_info = ExceptionCapture.build_parsed_exception(exception)

      return if exception_info.nil?

      no_distinct_id_was_provided = distinct_id.nil?
      distinct_id ||= SecureRandom.uuid

      properties = { '$exception_list' => [exception_info] }
      properties.merge!(additional_properties) if additional_properties && !additional_properties.empty?
      properties['$process_person_profile'] = false if no_distinct_id_was_provided

      event_data = {
        distinct_id: distinct_id,
        event: '$exception',
        properties: properties,
        timestamp: Time.now
      }
      event_data[:flags] = flags if flags

      capture(event_data)
    end

    # Identifies a user
    #
    # @param [Hash] attrs
    #
    # @option attrs [Hash] :properties User properties (optional)
    # @macro common_attrs
    def identify(attrs)
      symbolize_keys! attrs
      enqueue(FieldParser.parse_for_identify(attrs))
    end

    # Identifies a group
    #
    # @param [Hash] attrs
    #
    # @option attrs [String] :group_type Group type
    # @option attrs [String] :group_key Group key
    # @option attrs [Hash] :properties Group properties (optional)
    # @option attrs [String] :distinct_id Distinct ID (optional)
    # @macro common_attrs
    def group_identify(attrs)
      symbolize_keys! attrs
      enqueue(FieldParser.parse_for_group_identify(attrs))
    end

    # Aliases a user from one id to another
    #
    # @param [Hash] attrs
    #
    # @option attrs [String] :alias The alias to give the distinct id
    # @macro common_attrs
    def alias(attrs)
      symbolize_keys! attrs
      enqueue(FieldParser.parse_for_alias(attrs))
    end

    # @return [Hash] pops the last message from the queue
    def dequeue_last_message
      @queue.pop
    end

    # @return [Fixnum] number of messages in the queue
    def queued_messages
      @queue.length
    end

    # @deprecated Use {#evaluate_flags} and {FeatureFlagEvaluations#is_enabled} instead.
    # TODO: In future version, rename to `feature_flag_enabled?`
    def is_feature_enabled( # rubocop:disable Naming/PredicateName
      flag_key,
      distinct_id,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false,
      send_feature_flag_events: true
    )
      _emit_deprecation(
        :is_feature_enabled,
        '`is_feature_enabled` is deprecated and will be removed in a future major version. ' \
        'Use `client.evaluate_flags(distinct_id, ...)` and call `flags.enabled?(key)` instead — ' \
        'this consolidates flag evaluation into a single `/flags` request per incoming request.'
      )
      # Bypass the public `get_feature_flag` so the user only sees a single deprecation
      # warning per call, not a cascade.
      result = _get_feature_flag_result(
        flag_key, distinct_id,
        groups: groups, person_properties: person_properties, group_properties: group_properties,
        only_evaluate_locally: only_evaluate_locally, send_feature_flag_events: send_feature_flag_events
      )
      response = result&.value
      return nil if response.nil?

      !!response
    end

    # @param [String] flag_key The unique flag key of the feature flag
    # @return [String] The decrypted value of the feature flag payload
    def get_remote_config_payload(flag_key)
      @feature_flags_poller.get_remote_config_payload(flag_key)
    end

    # Returns whether the given feature flag is enabled for the given user or not
    #
    # @param [String] key The key of the feature flag
    # @param [String] distinct_id The distinct id of the user
    # @param [Hash] groups
    # @param [Hash] person_properties key-value pairs of properties to associate with the user.
    # @param [Hash] group_properties
    #
    # @return [String, nil] The value of the feature flag
    #
    # The provided properties are used to calculate feature flags locally, if possible.
    #
    # `groups` are a mapping from group type to group key. So, if you have a group type of "organization"
    # and a group key of "5",
    # you would pass groups={"organization": "5"}.
    # `group_properties` take the format: { group_type_name: { group_properties } }
    # So, for example, if you have the group type "organization" and the group key "5", with the properties name,
    # and employee count, you'll send these as:
    # ```ruby
    #     group_properties: {"organization": {"name": "PostHog", "employees": 11}}
    # ```
    # @deprecated Use {#evaluate_flags} and {FeatureFlagEvaluations#get_flag} instead.
    def get_feature_flag(
      key,
      distinct_id,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false,
      send_feature_flag_events: true
    )
      _emit_deprecation(
        :get_feature_flag,
        '`get_feature_flag` is deprecated and will be removed in a future major version. ' \
        'Use `client.evaluate_flags(distinct_id, ...)` and call `flags.get_flag(key)` instead — ' \
        'this consolidates flag evaluation into a single `/flags` request per incoming request.'
      )
      # Bypass the public `get_feature_flag_result` so the user only sees one deprecation warning.
      result = _get_feature_flag_result(
        key, distinct_id,
        groups: groups, person_properties: person_properties, group_properties: group_properties,
        only_evaluate_locally: only_evaluate_locally, send_feature_flag_events: send_feature_flag_events
      )
      result&.value
    end

    # @deprecated Use {#evaluate_flags} and {FeatureFlagEvaluations#get_flag} /
    #   {FeatureFlagEvaluations#get_flag_payload} instead.
    def get_feature_flag_result(
      key,
      distinct_id,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false,
      send_feature_flag_events: true
    )
      _emit_deprecation(
        :get_feature_flag_result,
        '`get_feature_flag_result` is deprecated and will be removed in a future major version. ' \
        'Use `client.evaluate_flags(distinct_id, ...)` and call `flags.get_flag(key)` / ' \
        '`flags.get_flag_payload(key)` instead — this consolidates flag evaluation into a single ' \
        '`/flags` request per incoming request.'
      )
      _get_feature_flag_result(
        key, distinct_id,
        groups: groups, person_properties: person_properties, group_properties: group_properties,
        only_evaluate_locally: only_evaluate_locally, send_feature_flag_events: send_feature_flag_events
      )
    end

    # Evaluate feature flags for a distinct id and return a snapshot.
    #
    # The returned {PostHog::FeatureFlagEvaluations} can be queried with
    # `is_enabled` / `get_flag` / `get_flag_payload`, narrowed with
    # `only_accessed` / `only`, and passed to {#capture} via the `flags:` option
    # to attach `$feature/<key>` and `$active_feature_flags` without an extra
    # /flags request.
    #
    # @param [String] distinct_id The distinct id of the user
    # @param [Hash] groups
    # @param [Hash] person_properties key-value pairs of properties to associate with the user
    # @param [Hash] group_properties
    # @param [Boolean] only_evaluate_locally Skip the remote /flags call entirely
    # @param [Boolean] disable_geoip Stamped on captured access events
    # @param [Array<String>] flag_keys When set, scopes the underlying /flags
    #   request to only these flag keys (sent as `flag_keys_to_evaluate`).
    #   Distinct from {FeatureFlagEvaluations#only}, which filters the
    #   already-fetched snapshot in memory.
    # @return [PostHog::FeatureFlagEvaluations]
    def evaluate_flags(
      distinct_id,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false,
      disable_geoip: nil,
      flag_keys: nil
    )
      host = _feature_flag_evaluations_host

      if distinct_id.nil? || distinct_id.to_s.empty?
        return FeatureFlagEvaluations.new(host: host, distinct_id: '', flags: {})
      end

      person_properties, group_properties = add_local_person_and_group_properties(
        distinct_id, groups, person_properties, group_properties
      )

      records = {}
      locally_evaluated_keys = Set.new
      flag_keys_set = flag_keys&.to_set(&:to_s)

      @feature_flags_poller.load_feature_flags
      poller_flags_by_key = @feature_flags_poller.feature_flags_by_key || {}

      poller_flags_by_key.each do |key, definition|
        next if flag_keys_set && !flag_keys_set.include?(key.to_s)

        begin
          match = @feature_flags_poller.send(
            :_compute_flag_locally,
            definition, distinct_id, groups, person_properties, group_properties
          )
        rescue PostHog::RequiresServerEvaluation, PostHog::InconclusiveMatchError, StandardError
          next
        end

        next if match.nil?

        records[key.to_s] = FeatureFlagEvaluations::EvaluatedFlagRecord.new(
          key: key.to_s,
          enabled: match.is_a?(String) || (match ? true : false),
          variant: match.is_a?(String) ? match : nil,
          payload: FeatureFlagResult.parse_payload(
            @feature_flags_poller.send(:_compute_flag_payload_locally, key, match)
          ),
          id: definition[:id],
          version: nil,
          reason: FeatureFlagEvaluations::EVALUATED_LOCALLY_REASON,
          locally_evaluated: true
        )
        locally_evaluated_keys << key.to_s
      end

      request_id = nil
      evaluated_at = nil
      errors_while_computing = false
      quota_limited = false

      # Skip the remote `/flags` round-trip when the caller scoped the request
      # to a fixed set of `flag_keys` and we've already resolved every one of
      # them locally. Without `flag_keys` set, we can't know whether the server
      # has flags we don't have definitions for, so we still hit `/flags`.
      all_requested_flags_resolved_locally = flag_keys_set && (flag_keys_set - locally_evaluated_keys).empty?

      if !only_evaluate_locally && !all_requested_flags_resolved_locally
        begin
          flags_response = @feature_flags_poller.get_flags(
            distinct_id, groups, person_properties, group_properties, flag_keys, disable_geoip
          )
          request_id = flags_response[:requestId]
          evaluated_at = flags_response[:evaluatedAt]
          errors_while_computing = flags_response[:errorsWhileComputingFlags] == true
          quota_limited = (flags_response[:quotaLimited] || []).include?('feature_flags')
          remote_flags = flags_response[:flags] || {}
          remote_flags.each do |key, ff|
            key_str = key.to_s
            next if locally_evaluated_keys.include?(key_str)

            metadata = ff.metadata
            reason = ff.reason
            records[key_str] = FeatureFlagEvaluations::EvaluatedFlagRecord.new(
              key: key_str,
              enabled: ff.enabled ? true : false,
              variant: ff.variant,
              payload: FeatureFlagResult.parse_payload(ff.payload),
              id: metadata ? metadata.id : nil,
              version: metadata ? metadata.version : nil,
              reason: reason ? (reason.description || reason.code) : nil,
              locally_evaluated: false
            )
          end
        rescue StandardError => e
          @on_error&.call(-1, "Error evaluating flags remotely: #{e}")
        end
      end

      FeatureFlagEvaluations.new(
        host: host,
        distinct_id: distinct_id,
        flags: records,
        groups: groups,
        disable_geoip: disable_geoip,
        request_id: request_id,
        evaluated_at: evaluated_at,
        flag_definitions_loaded_at: @feature_flags_poller.flag_definitions_loaded_at,
        errors_while_computing: errors_while_computing,
        quota_limited: quota_limited
      )
    end

    # Returns all flags for a given user
    #
    # @param [String] distinct_id The distinct id of the user
    # @param [Hash] groups
    # @param [Hash] person_properties key-value pairs of properties to associate with the user.
    # @param [Hash] group_properties
    #
    # @return [Hash] String (not symbol) key value pairs of flag and their values
    def get_all_flags(
      distinct_id,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false
    )
      person_properties, group_properties = add_local_person_and_group_properties(distinct_id, groups,
                                                                                  person_properties, group_properties)
      @feature_flags_poller.get_all_flags(distinct_id, groups, person_properties, group_properties,
                                          only_evaluate_locally)
    end

    # Returns payload for a given feature flag
    #
    # @deprecated Use {#get_feature_flag_result} instead, which returns both the flag value and payload
    #   and properly raises the $feature_flag_called event.
    #
    # @param [String] key The key of the feature flag
    # @param [String] distinct_id The distinct id of the user
    # @option [String or boolean] match_value The value of the feature flag to be matched
    # @option [Hash] groups
    # @option [Hash] person_properties key-value pairs of properties to associate with the user.
    # @option [Hash] group_properties
    # @option [Boolean] only_evaluate_locally
    #
    # @deprecated Use {#evaluate_flags} and {FeatureFlagEvaluations#get_flag_payload} instead.
    def get_feature_flag_payload(
      key,
      distinct_id,
      match_value: nil,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false
    )
      _emit_deprecation(
        :get_feature_flag_payload,
        '`get_feature_flag_payload` is deprecated and will be removed in a future major version. ' \
        'Use `client.evaluate_flags(distinct_id, ...)` and call `flags.get_flag_payload(key)` ' \
        'instead — this consolidates flag evaluation into a single `/flags` request per ' \
        'incoming request.'
      )
      person_properties, group_properties = add_local_person_and_group_properties(distinct_id, groups,
                                                                                  person_properties, group_properties)
      @feature_flags_poller.get_feature_flag_payload(key, distinct_id, match_value, groups, person_properties,
                                                     group_properties, only_evaluate_locally)
    end

    # Returns all flags and payloads for a given user
    #
    # @return [Hash] A hash with the following keys:
    #   featureFlags: A hash of feature flags
    #   featureFlagPayloads: A hash of feature flag payloads
    #
    # @param [String] distinct_id The distinct id of the user
    # @option [Hash] groups
    # @option [Hash] person_properties key-value pairs of properties to associate with the user.
    # @option [Hash] group_properties
    # @option [Boolean] only_evaluate_locally
    #
    def get_all_flags_and_payloads(
      distinct_id,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false
    )
      person_properties, group_properties = add_local_person_and_group_properties(
        distinct_id, groups, person_properties, group_properties
      )
      response = @feature_flags_poller.get_all_flags_and_payloads(
        distinct_id, groups, person_properties, group_properties, only_evaluate_locally
      )

      # Remove internal information
      response.delete(:requestId)
      response.delete(:evaluatedAt)
      response
    end

    def reload_feature_flags
      unless @personal_api_key
        logger.error(
          'You need to specify a personal_api_key to locally evaluate feature flags'
        )
        return
      end
      @feature_flags_poller.load_feature_flags(true)
    end

    def shutdown
      self.class._decrement_instance_count(@api_key) if @api_key
      @feature_flags_poller.shutdown_poller
      flush
      if @sync_mode
        @sync_lock.synchronize { @transport&.shutdown }
      else
        @worker&.shutdown
      end
    end

    private

    # Shared by the legacy single-flag path ({#get_feature_flag_result}) and the
    # snapshot's access-recording. Owns dedup-key construction, the
    # per-distinct_id sent-flags cache, and the `$feature_flag_called` capture call.
    def _capture_feature_flag_called_if_needed(
      distinct_id: nil, key: nil, response: nil, properties: nil,
      groups: nil, disable_geoip: nil
    )
      reported_key = "#{key}_#{response.nil? ? '::null::' : response}"
      return if @distinct_id_has_sent_flag_calls[distinct_id].include?(reported_key)

      msg = {
        distinct_id: distinct_id,
        event: '$feature_flag_called',
        properties: properties
      }
      msg[:groups] = groups if groups
      msg[:disable_geoip] = disable_geoip unless disable_geoip.nil?

      capture(msg)
      @distinct_id_has_sent_flag_calls[distinct_id] << reported_key
    end

    def _feature_flag_evaluations_host
      @feature_flag_evaluations_host ||= FeatureFlagEvaluations::Host.new(
        capture_flag_called_event_if_needed: method(:_capture_feature_flag_called_if_needed),
        log_warning: ->(message) { logger.warn(message) }
      )
    end

    # Implementation of {#get_feature_flag_result}, called by both the public
    # method and the legacy `is_feature_enabled` / `get_feature_flag` paths so
    # a single user-level call emits exactly one deprecation warning.
    def _get_feature_flag_result(
      key,
      distinct_id,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false,
      send_feature_flag_events: true
    )
      person_properties, group_properties = add_local_person_and_group_properties(
        distinct_id, groups, person_properties, group_properties
      )
      feature_flag_response, flag_was_locally_evaluated, request_id, evaluated_at, feature_flag_error, payload =
        @feature_flags_poller.get_feature_flag(
          key, distinct_id, groups, person_properties, group_properties, only_evaluate_locally
        )
      if send_feature_flag_events
        properties = {
          '$feature_flag' => key,
          '$feature_flag_response' => feature_flag_response,
          'locally_evaluated' => flag_was_locally_evaluated
        }
        properties['$feature_flag_request_id'] = request_id if request_id
        properties['$feature_flag_evaluated_at'] = evaluated_at if evaluated_at
        properties['$feature_flag_error'] = feature_flag_error if feature_flag_error

        _capture_feature_flag_called_if_needed(
          distinct_id: distinct_id, key: key, response: feature_flag_response,
          properties: properties, groups: groups
        )
      end

      FeatureFlagResult.from_value_and_payload(key, feature_flag_response, payload)
    end

    # Emits a deprecation warning at most once per `(method_name, process)` pair.
    # Ruby's `Kernel.warn(..., category: :deprecated)` is suppressed by default
    # since 2.7.2; we emit without the category so messages reach users on a
    # default Ruby setup. Standard logger configuration / `$VERBOSE = nil` / IO
    # redirection still silences as expected.
    def _emit_deprecation(method_name, message)
      return unless @deprecation_emitted_for.add?(method_name)

      Kernel.warn("[posthog-ruby] DEPRECATION: #{message}", uplevel: 2)
    end

    # before_send should run immediately before the event is sent to the queue.
    # @param [Object] action The event to be sent to PostHog
    # @return [null, Object, nil] The processed event or nil if the event should not be sent
    def process_before_send(action)
      return action if action.nil? || action.empty?
      return action unless @before_send

      begin
        processed_action = @before_send.call(action)

        if processed_action.nil?
          logger.warn("Event #{action[:event]} was rejected in beforeSend function")
        elsif processed_action.empty?
          logger.warn("Event #{action[:event]} has no properties after beforeSend function, this is likely an error")
        end

        processed_action
      rescue StandardError => e
        logger.error("Error in beforeSend function - using original event: #{e.message}")
        action
      end
    end

    # private: Enqueues the action.
    #
    # returns Boolean of whether the item was added to the queue.
    def enqueue(action)
      action = process_before_send(action)
      return false if action.nil? || action.empty?

      # add our request id for tracing purposes
      action[:messageId] ||= uid

      if @sync_mode
        send_sync(action)
        return true
      end

      if @queue.length < @max_queue_size
        @queue << action
        ensure_worker_running

        true
      else
        logger.warn(
          'Queue is full, dropping events. The :max_queue_size ' \
          'configuration parameter can be increased to prevent this from ' \
          'happening.'
        )
        false
      end
    end

    # private: Checks that the api_key is properly initialized
    def check_api_key!
      raise ArgumentError, 'API key must be initialized' if @api_key.nil?
    end

    def normalize_string_option(value, blank_as_nil: false)
      return value unless value.is_a?(String)

      normalized = value.strip
      return nil if blank_as_nil && normalized.empty?

      normalized
    end

    def normalize_host_option(host)
      normalized = normalize_string_option(host)
      return 'https://us.i.posthog.com' if normalized.nil? || normalized.empty?

      normalized
    end

    def ensure_worker_running
      return if worker_running?

      @worker_mutex.synchronize do
        return if worker_running?

        @worker_thread = Thread.new { @worker.run }
      end
    end

    def send_sync(action)
      batch = MessageBatch.new(1)
      begin
        batch << action
      rescue MessageBatch::JSONGenerationError => e
        @on_error.call(-1, e.to_s)
        return
      end
      return if batch.empty?

      @sync_lock.synchronize do
        res = @transport.send(@api_key, batch)
        @on_error.call(res.status, res.error) unless res.status == 200
      end
    end

    def worker_running?
      @worker_thread&.alive?
    end

    def add_local_person_and_group_properties(distinct_id, groups, person_properties, group_properties)
      groups ||= {}
      person_properties ||= {}
      group_properties ||= {}

      symbolize_keys! groups
      symbolize_keys! person_properties
      symbolize_keys! group_properties

      group_properties.each_value do |value|
        symbolize_keys! value
      end

      all_person_properties = { distinct_id: distinct_id }.merge(person_properties)

      all_group_properties = {}
      groups&.each do |group_name, group_key|
        all_group_properties[group_name] = {
          '$group_key': group_key
        }.merge((group_properties && group_properties[group_name]) || {})
      end

      [all_person_properties, all_group_properties]
    end
  end
end
