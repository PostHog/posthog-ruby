require 'thread'
require 'time'

require 'posthog/defaults'
require 'posthog/logging'
require 'posthog/utils'
require 'posthog/send_worker'
require 'posthog/noop_worker'
require 'posthog/feature_flags'
require 'posthog/feature_flag_evaluations'

class PostHog
  class Client
    include PostHog::Utils
    include PostHog::Logging

    # @param [Hash] opts
    # @option opts [String] :api_key Your project's api_key
    # @option opts [String] :personal_api_key Your personal API key
    # @option opts [FixNum] :max_queue_size Maximum number of calls to be
    #   remain queued. Defaults to 10_000.
    # @option opts [Bool] :test_mode +true+ if messages should remain
    #   queued for testing. Defaults to +false+.
    # @option opts [Proc] :on_error Handles error calls from the API.
    # @option opts [String] :host Fully qualified hostname of the PostHog server. Defaults to `https://app.posthog.com`
    # @option opts [Integer] :feature_flags_polling_interval How often to poll for feature flag definition changes.
    #   Measured in seconds, defaults to 30.
    # @option opts [Integer] :feature_flag_request_timeout_seconds How long to wait for feature flag evaluation.
    #   Measured in seconds, defaults to 3.
    def initialize(opts = {})
      symbolize_keys!(opts)

      opts[:host] ||= 'https://app.posthog.com'

      @queue = Queue.new
      @api_key = opts[:api_key]
      @max_queue_size = opts[:max_queue_size] || Defaults::Queue::MAX_SIZE
      @worker_mutex = Mutex.new
      @worker = if opts[:test_mode]
                  NoopWorker.new(@queue)
                else
                  SendWorker.new(@queue, @api_key, opts)
                end
      @worker_thread = nil
      @feature_flags_poller = nil
      @personal_api_key = opts[:personal_api_key]
      @feature_flags_log_warnings = opts.key?(:feature_flags_log_warnings) ? opts[:feature_flags_log_warnings] : true

      check_api_key!

      @feature_flags_poller =
        FeatureFlagsPoller.new(
          opts[:feature_flags_polling_interval],
          opts[:personal_api_key],
          @api_key,
          opts[:host],
          opts[:feature_flag_request_timeout_seconds] || Defaults::FeatureFlags::FLAG_REQUEST_TIMEOUT_SECONDS,
          opts[:on_error]
        )

      @distinct_id_has_sent_flag_calls = SizeLimitedHash.new(Defaults::MAX_HASH_SIZE) do |hash, key|
        hash[key] = []
      end
    end

    # Synchronously waits until the worker has cleared the queue.
    #
    # Use only for scripts which are not long-running, and will specifically
    # exit
    def flush
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
    # @option attrs [Bool] :send_feature_flags Whether to send feature flags with this event (optional)
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

      if attrs[:flags]
        snapshot_props = attrs[:flags]._get_event_properties
        attrs[:properties] = snapshot_props.merge(attrs[:properties] || {})
        attrs.delete(:flags)
        attrs.delete(:send_feature_flags)
      elsif attrs[:send_feature_flags]
        feature_variants = @feature_flags_poller.get_feature_variants(attrs[:distinct_id], attrs[:groups] || {})

        attrs[:feature_variants] = feature_variants
      end

      enqueue(FieldParser.parse_for_capture(attrs))
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
      response = get_feature_flag(
        flag_key,
        distinct_id,
        groups: groups,
        person_properties: person_properties,
        group_properties: group_properties,
        only_evaluate_locally: only_evaluate_locally,
        send_feature_flag_events: send_feature_flag_events
      )
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
    def get_feature_flag(
      key,
      distinct_id,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false,
      send_feature_flag_events: true
    )
      person_properties, group_properties = add_local_person_and_group_properties(
        distinct_id,
        groups,
        person_properties,
        group_properties
      )
      feature_flag_response, flag_was_locally_evaluated, request_id = @feature_flags_poller.get_feature_flag(
        key,
        distinct_id,
        groups,
        person_properties,
        group_properties,
        only_evaluate_locally
      )

      if send_feature_flag_events
        properties = {
          '$feature_flag' => key,
          '$feature_flag_response' => feature_flag_response,
          'locally_evaluated' => flag_was_locally_evaluated
        }
        properties['$feature_flag_request_id'] = request_id if request_id

        _capture_feature_flag_called_if_needed(
          distinct_id: distinct_id,
          key: key,
          response: feature_flag_response,
          properties: properties,
          groups: groups
        )
      end
      feature_flag_response
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

      @feature_flags_poller.load_feature_flags
      poller_flags_by_key = @feature_flags_poller.feature_flags_by_key || {}

      poller_flags_by_key.each do |key, definition|
        next if flag_keys && !flag_keys.map(&:to_s).include?(key.to_s)

        begin
          match = @feature_flags_poller.send(
            :_compute_flag_locally,
            definition, distinct_id, groups, person_properties, group_properties
          )
        rescue PostHog::InconclusiveMatchError, StandardError
          next
        end

        next if match.nil?

        records[key] = FeatureFlagEvaluations::EvaluatedFlagRecord.new(
          key: key,
          enabled: match.is_a?(String) || (match ? true : false),
          variant: match.is_a?(String) ? match : nil,
          payload: @feature_flags_poller.send(:_compute_flag_payload_locally, key, match),
          id: definition[:id],
          version: nil,
          reason: FeatureFlagEvaluations::EVALUATED_LOCALLY_REASON,
          locally_evaluated: true
        )
        locally_evaluated_keys << key
      end

      request_id = nil
      evaluated_at = nil

      unless only_evaluate_locally
        begin
          flags_response = @feature_flags_poller.get_flags(
            distinct_id, groups, person_properties, group_properties,
            flag_keys: flag_keys
          )
          request_id = flags_response[:requestId]
          evaluated_at = flags_response[:evaluatedAt]
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
              payload: ff.payload,
              id: metadata ? metadata.id : nil,
              version: metadata ? metadata.version : nil,
              reason: reason ? (reason.description || reason.code) : nil,
              locally_evaluated: false
            )
          end
        rescue StandardError => e
          on_error = @feature_flags_poller.instance_variable_get(:@on_error)
          on_error.call(-1, "Error evaluating flags remotely: #{e}") if on_error
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
        flag_definitions_loaded_at: @feature_flags_poller.flag_definitions_loaded_at
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
    # @param [String] key The key of the feature flag
    # @param [String] distinct_id The distinct id of the user
    # @option [String or boolean] match_value The value of the feature flag to be matched
    # @option [Hash] groups
    # @option [Hash] person_properties key-value pairs of properties to associate with the user.
    # @option [Hash] group_properties
    # @option [Boolean] only_evaluate_locally
    #
    def get_feature_flag_payload(
      key,
      distinct_id,
      match_value: nil,
      groups: {},
      person_properties: {},
      group_properties: {},
      only_evaluate_locally: false
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

      response.delete(:requestId) # remove internal information.
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
      @feature_flags_poller.shutdown_poller
      flush
    end

    private

    # Shared by the legacy single-flag path and FeatureFlagEvaluations#_record_access.
    # Owns dedup-key construction, the per-distinct_id sent-flags cache, and the
    # `$feature_flag_called` capture call.
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
        log_warning: lambda do |message|
          logger.warn(message) if @feature_flags_log_warnings
        end
      )
    end

    # private: Enqueues the action.
    #
    # returns Boolean of whether the item was added to the queue.
    def enqueue(action)
      # add our request id for tracing purposes
      action[:messageId] ||= uid

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

    def ensure_worker_running
      return if worker_running?

      @worker_mutex.synchronize do
        return if worker_running?

        @worker_thread = Thread.new { @worker.run }
      end
    end

    def worker_running?
      @worker_thread && @worker_thread.alive?
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
      if groups
        groups.each do |group_name, group_key|
          all_group_properties[group_name] = {
            :'$group_key' => group_key
          }.merge((group_properties && group_properties[group_name]) || {})
        end
      end

      [all_person_properties, all_group_properties]
    end
  end
end
