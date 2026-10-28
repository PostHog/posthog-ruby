# frozen_string_literal: true

require 'concurrent'
require 'net/http'
require 'json'
require 'posthog/version'
require 'posthog/logging'
require 'posthog/defaults'
require 'posthog/backoff_policy'
require 'posthog/feature_flag'
require 'posthog/flag_definition_cache'
require 'posthog/unresolved_flag_reason'
require 'posthog/flag_evaluation_errors'
require 'digest'
require 'set'

module PostHog
  # Polls and evaluates feature flag definitions for {PostHog::Client}.
  #
  # @api private
  class FeatureFlagsPoller
    include PostHog::Logging
    include PostHog::Utils

    # When several causes apply to one flag, the spec reports the first reason in this order, so
    # every SDK picks the same reason whatever order it inspects the filters in.
    UNRESOLVED_REASON_PRECEDENCE = [
      UnresolvedFlagReason::EXPERIENCE_CONTINUITY,
      UnresolvedFlagReason::UNSUPPORTED_DEFINITION,
      UnresolvedFlagReason::UNRESOLVED_DEPENDENCY,
      UnresolvedFlagReason::MISSING_CONTEXT
    ].freeze

    # Operator groups that share one branch in both match_property_value and assert_filter_supported,
    # so the load-time check stays in step with evaluation.
    REGEX_OPERATORS = %w[regex not_regex].freeze
    NUMERIC_OPERATORS = %w[gt gte lt lte].freeze
    DATE_OPERATORS = %w[is_date_before is_date_after].freeze
    SEMVER_COMPARISON_OPERATORS = %w[semver_eq semver_neq semver_gt semver_gte semver_lt semver_lte].freeze

    # @param polling_interval [Integer, nil] Seconds between local feature flag definition polls.
    #   Defaults to {Defaults::FeatureFlags::POLLING_INTERVAL_SECONDS}.
    # @param secret_key [String, nil] Credential used to fetch local evaluation definitions. Accepts either a
    #   Personal API Key (`phx_...`) or a Project Secret API Key (`phs_...`).
    # @param project_api_key [String] Project API key.
    # @param host [String] PostHog API host URL.
    # @param feature_flag_request_timeout_seconds [Integer] Timeout for feature flag requests.
    # @param on_error [Proc, nil] Callback invoked as `on_error.call(status, error)`.
    # @param flag_definition_cache_provider [Object, nil] Optional {FlagDefinitionCacheProvider} implementation.
    # @param feature_flag_request_max_retries [Integer, nil] Retries after a transient network error or retryable
    #   HTTP response status on a flag request. Defaults to {Defaults::FeatureFlags::FLAG_REQUEST_MAX_RETRIES}.
    #   Set to 0 to disable retrying.
    # @param async_load [Boolean] When true, flag definitions are fetched only on the poller thread: an
    #   immediate first tick at construction, then the regular polling cadence, which keeps retrying until a
    #   load succeeds.
    # @param user_agent [String] User-Agent header sent with feature flag requests.
    # @param flag_definitions_update_mutex [Mutex] Internal lock shared with flag-called deduplication.
    # @param on_flag_definitions_updated [Proc, nil] Internal callback after definitions are applied or discarded,
    #   called while holding flag_definitions_update_mutex.
    def initialize(
      polling_interval,
      secret_key,
      project_api_key,
      host,
      feature_flag_request_timeout_seconds,
      on_error = nil,
      flag_definition_cache_provider: nil,
      feature_flag_request_max_retries: nil,
      async_load: false,
      user_agent: "posthog-ruby/#{PostHog::VERSION}",
      on_flag_definitions_updated: nil,
      flag_definitions_update_mutex: Mutex.new
    )
      @polling_interval = polling_interval || Defaults::FeatureFlags::POLLING_INTERVAL_SECONDS
      @secret_key = secret_key
      @project_api_key = project_api_key
      @host = host
      @feature_flags = Concurrent::Array.new
      @group_type_mapping = Concurrent::Hash.new
      @cohorts = Concurrent::Hash.new
      @loaded_flags_successfully_once = Concurrent::AtomicBoolean.new
      @feature_flags_by_key = nil
      @feature_flag_request_timeout_seconds = feature_flag_request_timeout_seconds
      @feature_flag_request_max_retries =
        feature_flag_request_max_retries || Defaults::FeatureFlags::FLAG_REQUEST_MAX_RETRIES
      @on_error = on_error || proc { |status, error| }
      @quota_limited = Concurrent::AtomicBoolean.new(false)
      @flags_etag = Concurrent::AtomicReference.new(nil)
      @flag_definitions_loaded_at = Concurrent::AtomicReference.new(nil)
      @async_load = async_load
      @user_agent = user_agent
      @on_flag_definitions_updated = on_flag_definitions_updated
      @flag_definitions_update_mutex = flag_definitions_update_mutex
      # Server-controlled gate for minimal `$feature_flag_called` events, read
      # from the top-level `minimal_flag_called_events` key of the local
      # evaluation definitions payload. false when the server does not send it.
      @minimal_flag_called_events = false
      # Definition fingerprint per flag key already warned about as never locally resolvable.
      @warned_unresolvable_flags = {}
      @definition_snapshot = Concurrent::AtomicReference.new({
        flags: @feature_flags, flags_by_key: @feature_flags_by_key,
        group_type_mapping: @group_type_mapping, cohorts: @cohorts,
        minimal_flag_called_events: @minimal_flag_called_events, property_matching_version: 1
      }.freeze)
      @flag_definition_cache_provider = flag_definition_cache_provider
      FlagDefinitionCacheProvider.validate!(@flag_definition_cache_provider) if @flag_definition_cache_provider

      @task =
        Concurrent::TimerTask.new(
          execution_interval: @polling_interval,
          run_now: @async_load
        ) { _load_feature_flags }

      # Local evaluation can load definitions from either the API or an external cache.
      if @secret_key.nil? && @flag_definition_cache_provider.nil?
        logger.info 'No secret_key or flag_definition_cache_provider provided, disabling local evaluation'
        @loaded_flags_successfully_once.make_true
      else
        # load once synchronously before timer, unless @async_load
        load_feature_flags unless @async_load
        @task.execute
      end
    end

    def load_feature_flags(force_reload = false)
      return if (@loaded_flags_successfully_once.true? || @async_load) && !force_reload

      _load_feature_flags
    end

    # Whether flag definitions are currently loaded. False until the first
    # successful load, and false again if a quota-limited (402) response
    # discards them.
    def definitions_loaded?
      !@flag_definitions_loaded_at.value.nil?
    end

    # Epoch milliseconds of the last successful definitions load, or nil.
    def flag_definitions_loaded_at
      @flag_definitions_loaded_at.value
    end

    attr_reader :feature_flags_by_key, :minimal_flag_called_events

    def get_feature_variants(
      distinct_id,
      groups = {},
      person_properties = {},
      group_properties = {},
      only_evaluate_locally = false,
      raise_on_error = false
    )
      # TODO: Convert to options hash for easier argument passing
      flags_data = get_all_flags_and_payloads(
        distinct_id,
        groups,
        person_properties,
        group_properties,
        only_evaluate_locally,
        raise_on_error
      )

      if flags_data.key?(:featureFlags)
        stringify_keys(flags_data[:featureFlags] || {})
      else
        logger.debug "Missing feature flags key: #{flags_data.to_json}"
        {}
      end
    end

    def get_feature_payloads(
      distinct_id,
      groups = {},
      person_properties = {},
      group_properties = {},
      _only_evaluate_locally = false
    )
      flags_data = get_all_flags_and_payloads(
        distinct_id,
        groups,
        person_properties,
        group_properties
      )

      if flags_data.key?(:featureFlagPayloads)
        stringify_keys(flags_data[:featureFlagPayloads] || {})
      else
        logger.debug "Missing feature flag payloads key: #{flags_data.to_json}"
        {}
      end
    end

    def get_flags(distinct_id, groups = {}, person_properties = {}, group_properties = {}, flag_keys = nil,
                  disable_geoip = nil)
      flag_keys = flag_keys.map(&:to_s) if flag_keys.is_a?(Array)
      request_data = {
        distinct_id: distinct_id,
        groups: groups,
        person_properties: person_properties,
        group_properties: group_properties
      }
      request_data[:flag_keys_to_evaluate] = flag_keys if flag_keys && !flag_keys.empty?
      request_data[:geoip_disable] = disable_geoip unless disable_geoip.nil?

      flags_response = _request_feature_flag_evaluation(request_data)

      # Only normalize if we have flags in the response
      if flags_response[:flags]
        # v4 format
        flags_hash = flags_response[:flags].transform_values do |flag|
          FeatureFlag.new(flag)
        end
        flags_response[:flags] = flags_hash
        # Filter out flags that failed evaluation to avoid overwriting cached values
        successful_flags = flags_hash.reject { |_, flag| flag.failed == true }
        flags_response[:featureFlags] = successful_flags.transform_values(&:get_value).transform_keys(&:to_sym)
        flags_response[:featureFlagPayloads] = successful_flags.transform_values(&:payload).transform_keys(&:to_sym)
      elsif flags_response[:featureFlags]
        # v3 format
        flags_response[:featureFlags] = flags_response[:featureFlags] || {}
        flags_response[:featureFlagPayloads] = flags_response[:featureFlagPayloads] || {}
        flags_response[:flags] = flags_response[:featureFlags].to_h do |key, value|
          [key, FeatureFlag.from_value_and_payload(key, value, flags_response[:featureFlagPayloads][key])]
        end
      end

      flags_response
    end

    def get_remote_config_payload(flag_key)
      _request_remote_config_payload(flag_key.to_s)
    end

    def get_feature_flag(
      key,
      distinct_id,
      groups = {},
      person_properties = {},
      group_properties = {},
      only_evaluate_locally = false,
      snapshot: nil
    )
      key = key.to_s

      # make sure they're loaded on first run
      load_feature_flags
      snapshot ||= _evaluation_snapshot

      symbolize_keys! groups
      symbolize_keys! person_properties
      symbolize_keys! group_properties

      group_properties.each_value do |value|
        symbolize_keys!(value)
      end

      response = nil
      payload = nil
      feature_flag = snapshot[:flags_by_key]&.[](key)

      unless feature_flag.nil?
        begin
          response = _compute_flag_locally(feature_flag, distinct_id, groups, person_properties, group_properties,
                                           snapshot: snapshot)
          payload = _compute_flag_payload_locally(key, response, snapshot: snapshot) unless response.nil?
          logger.debug "Successfully computed flag locally: #{key} -> #{response}"
        rescue RequiresServerEvaluation, InconclusiveMatchError => e
          logger.debug "Failed to compute flag #{key} locally: #{e}"
        rescue StandardError => e
          @on_error.call(-1, "Error computing flag locally: #{e}. #{e.backtrace.join("\n")}")
        end
      end

      flag_was_locally_evaluated = !response.nil?
      # Whether the flag is linked to an experiment, as reported by the server.
      # Locally-evaluated flags carry it in the stored definition; remotely
      # evaluated flags carry it in the response metadata. nil when the server
      # (an older deployment) does not report it.
      has_experiment = feature_flag[:has_experiment] if flag_was_locally_evaluated
      # Server-controlled gate for minimal `$feature_flag_called` events.
      # Locally-evaluated flags read it from the definitions payload; remotely
      # evaluated flags read it from the /flags response. nil when the signal
      # is unavailable, which fails safe to the full event.
      minimal_flag_called_events = snapshot[:minimal_flag_called_events] if flag_was_locally_evaluated

      request_id = nil
      evaluated_at = nil
      feature_flag_error = nil

      if !flag_was_locally_evaluated && !only_evaluate_locally
        begin
          errors = []
          flags_data = get_all_flags_and_payloads(distinct_id, groups, person_properties, group_properties,
                                                  only_evaluate_locally, true)
          if flags_data.key?(:featureFlags)
            flags = stringify_keys(flags_data[:featureFlags] || {})
            payloads = stringify_keys(flags_data[:featureFlagPayloads] || {})
            request_id = flags_data[:requestId]
            evaluated_at = flags_data[:evaluatedAt]
          else
            logger.debug "Missing feature flags key: #{flags_data.to_json}"
            flags = {}
            payloads = {}
          end

          status = flags_data[:status]
          errors << FeatureFlagError.api_error(status) if status && status >= 400
          errors << FeatureFlagError::ERRORS_WHILE_COMPUTING if flags_data[:errorsWhileComputingFlags]
          errors << FeatureFlagError::QUOTA_LIMITED if flags_data[:quotaLimited]&.include?('feature_flags')
          errors << FeatureFlagError::FLAG_MISSING unless flags.key?(key.to_s)

          response = flags[key]
          response = false if response.nil?
          payload = payloads[key]
          feature_flag_error = errors.join(',') unless errors.empty?

          flag_detail = flags_data[:flagDetails]&.[](key.to_sym)
          has_experiment = flag_detail&.metadata&.has_experiment
          minimal_flag_called_events = flags_data[:minimalFlagCalledEvents]

          logger.debug "Successfully computed flag remotely: #{key} -> #{response}"
        rescue Timeout::Error => e
          @on_error.call(-1, "Timeout while fetching flags remotely: #{e}")
          feature_flag_error = FeatureFlagError::TIMEOUT
        rescue Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, SocketError => e
          @on_error.call(-1, "Connection error while fetching flags remotely: #{e}")
          feature_flag_error = FeatureFlagError::CONNECTION_ERROR
        rescue StandardError => e
          @on_error.call(-1, "Error computing flag remotely: #{e}. #{e.backtrace.join("\n")}")
          feature_flag_error = FeatureFlagError::UNKNOWN_ERROR
        end
      end

      [response, flag_was_locally_evaluated, request_id, evaluated_at, feature_flag_error, payload, has_experiment,
       minimal_flag_called_events]
    end

    def get_all_flags(
      distinct_id,
      groups = {},
      person_properties = {},
      group_properties = {},
      only_evaluate_locally = false
    )
      if @quota_limited.true?
        logger.debug 'Not fetching flags from server - quota limited'
        return {}
      end

      # returns a string hash of all flags
      response = get_all_flags_and_payloads(
        distinct_id,
        groups,
        person_properties,
        group_properties,
        only_evaluate_locally
      )

      response[:featureFlags]
    end

    def get_all_flags_and_payloads(
      distinct_id,
      groups = {},
      person_properties = {},
      group_properties = {},
      only_evaluate_locally = false,
      raise_on_error = false
    )
      load_feature_flags
      snapshot = _evaluation_snapshot

      flags = {}
      payloads = {}
      fallback_to_server = snapshot[:flags].empty?
      request_id = nil # Only for /flags requests
      evaluated_at = nil # Only for /flags requests

      snapshot[:flags].each do |flag|
        match_value = _compute_flag_locally(flag, distinct_id, groups, person_properties, group_properties,
                                            snapshot: snapshot)
        flags[flag[:key]] = match_value
        match_payload = _compute_flag_payload_locally(flag[:key], match_value, snapshot: snapshot)
        payloads[flag[:key]] = match_payload if match_payload
      rescue RequiresServerEvaluation, InconclusiveMatchError
        fallback_to_server = true
      rescue StandardError => e
        @on_error.call(-1, "Error computing flag locally: #{e}. #{e.backtrace.join("\n")} ")
        fallback_to_server = true
      end

      errors_while_computing = false
      quota_limited = nil
      status_code = nil
      flag_details = nil
      minimal_flag_called_events = nil

      if fallback_to_server && !only_evaluate_locally
        begin
          flags_and_payloads = get_flags(distinct_id, groups, person_properties, group_properties)
          flag_details = flags_and_payloads[:flags]
          errors_while_computing = flags_and_payloads[:errorsWhileComputingFlags] || false
          quota_limited = flags_and_payloads[:quotaLimited]
          status_code = flags_and_payloads[:status]

          unless flags_and_payloads.key?(:featureFlags)
            raise StandardError, "Error flags response: #{flags_and_payloads}"
          end

          request_id = flags_and_payloads[:requestId]
          evaluated_at = flags_and_payloads[:evaluatedAt]
          minimal_flag_called_events = flags_and_payloads[:minimalFlagCalledEvents]

          # Check if feature_flags are quota limited
          if quota_limited&.include?('feature_flags')
            logger.warn '[FEATURE FLAGS] Quota limited for feature flags'
            flags = {}
            payloads = {}
          else
            server_flags = stringify_keys(flags_and_payloads[:featureFlags] || {})
            server_payloads = stringify_keys(flags_and_payloads[:featureFlagPayloads] || {})

            if errors_while_computing
              # Merge server results into locally-evaluated results so that flags which
              # failed server-side evaluation (already filtered out by get_flags) don't
              # overwrite valid locally-evaluated values.
              flags = stringify_keys(flags).merge(server_flags)
              payloads = stringify_keys(payloads).merge(server_payloads)
            else
              flags = server_flags
              payloads = server_payloads
            end
          end
        rescue StandardError => e
          @on_error.call(-1, "Error computing flag remotely: #{e}")
          raise if raise_on_error
        end
      end

      {
        featureFlags: flags,
        featureFlagPayloads: payloads,
        flagDetails: flag_details,
        requestId: request_id,
        evaluatedAt: evaluated_at,
        errorsWhileComputingFlags: errors_while_computing,
        quotaLimited: quota_limited,
        status: status_code,
        minimalFlagCalledEvents: minimal_flag_called_events
      }
    end

    def get_feature_flag_payload(
      key,
      distinct_id,
      match_value = nil,
      groups = {},
      person_properties = {},
      group_properties = {},
      only_evaluate_locally = false
    )
      key = key.to_s
      load_feature_flags
      snapshot = _evaluation_snapshot

      if match_value.nil?
        match_value = get_feature_flag(
          key,
          distinct_id,
          groups,
          person_properties,
          group_properties,
          true,
          snapshot: snapshot
        )[0]
      end
      response = nil
      response = _compute_flag_payload_locally(key, match_value, snapshot: snapshot) unless match_value.nil?
      if response.nil? && !only_evaluate_locally
        flags_payloads = get_feature_payloads(distinct_id, groups, person_properties, group_properties)
        response = flags_payloads[key.downcase] || nil
      end
      response
    end

    def shutdown_poller
      @task.shutdown
      return unless @flag_definition_cache_provider

      begin
        @flag_definition_cache_provider.shutdown
      rescue StandardError => e
        logger.error("[FEATURE FLAGS] Cache provider shutdown error: #{e}")
      end
    end

    # Class methods

    def self.pick_unresolved_reason(current, reason)
      return reason if current.nil?

      UNRESOLVED_REASON_PRECEDENCE.index(reason) < UNRESOLVED_REASON_PRECEDENCE.index(current) ? reason : current
    end

    def self.compare(lhs, rhs, operator)
      case operator
      when 'gt'
        lhs > rhs
      when 'gte'
        lhs >= rhs
      when 'lt'
        lhs < rhs
      when 'lte'
        lhs <= rhs
      else
        raise "Invalid operator: #{operator}"
      end
    end

    def self.parse_finite_number(value)
      case value
      when String
        return unless /\A[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?\z/.match?(value)
      when Integer, Float
        # JSON numbers remain supported alongside numeric strings.
      else
        return unless defined?(::BigDecimal) && value.is_a?(::BigDecimal)
      end

      number = value.to_f
      number if number.finite?
    end
    private_class_method :parse_finite_number

    def self.relative_date_parse_for_feature_flag_matching(value)
      match = /^-?([0-9]+)([a-z])$/.match(value)
      parsed_dt = DateTime.now.new_offset(0)
      return unless match

      number = match[1].to_i

      if number >= 10_000
        # Guard against overflow, disallow numbers greater than 10_000
        return nil
      end

      interval = match[2]
      case interval
      when 'h'
        parsed_dt -= (number / 24.0)
      when 'd'
        parsed_dt = parsed_dt.prev_day(number)
      when 'w'
        parsed_dt = parsed_dt.prev_day(number * 7)
      when 'm'
        parsed_dt = parsed_dt.prev_month(number)
      when 'y'
        parsed_dt = parsed_dt.prev_year(number)
      else
        return nil
      end

      parsed_dt
    end

    # Parse a single semver numeric identifier, rejecting empty, non-digit, or
    # leading-zero values per semver 2.0.0 §2. `reason` names the owner of the value:
    # UNSUPPORTED_DEFINITION for a filter value, MISSING_CONTEXT for a value the call passed.
    def self.parse_semver_numeric(part, reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      if part.nil? || part.empty? || part !~ /^\d+$/
        raise InconclusiveMatchError.new('Invalid semver format', reason: reason)
      end
      # Semver 2.0.0 §2: numeric identifiers MUST NOT include leading zeros.
      raise InconclusiveMatchError.new('Invalid semver format', reason: reason) if part.length > 1 && part[0] == '0'

      part.to_i
    end

    # Parse a semver string into a comparable [major, minor, patch] integer array.
    # Handles v-prefix, whitespace, pre-release suffixes. Defaults missing components to 0.
    def self.parse_semver(value, reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      raise InconclusiveMatchError.new('Invalid semver format', reason: reason) if value.nil?

      text = value.to_s.strip.sub(/^[vV]/, '')

      raise InconclusiveMatchError.new('Invalid semver format', reason: reason) if text.empty?

      # Strip pre-release and build metadata suffixes
      text = text.split('-')[0].split('+')[0]
      parts = text.split('.')

      raise InconclusiveMatchError.new('Invalid semver format', reason: reason) if parts.empty? || parts[0].to_s.empty?

      major = parse_semver_numeric(parts[0], reason: reason)
      minor = parts.length > 1 ? parse_semver_numeric(parts[1], reason: reason) : 0
      patch = parts.length > 2 ? parse_semver_numeric(parts[2], reason: reason) : 0

      [major, minor, patch]
    end

    # Returns bounds for tilde (~) range:
    # ~X       → >=X.0.0 <(X+1).0.0
    # ~X.Y     → >=X.Y.0 <X.(Y+1).0
    # ~X.Y.Z   → >=X.Y.Z <X.(Y+1).0
    def self.semver_tilde_bounds(value)
      major, minor, patch = parse_semver(value)
      lower = [major, minor, patch]

      # Determine how many components were provided
      text = value.to_s.strip.sub(/^[vV]/, '')
      text = text.split('-')[0].split('+')[0]
      component_count = text.split('.').length

      upper = if component_count == 1
                # Major-only: bump major
                [major + 1, 0, 0]
              else
                # Major.minor or major.minor.patch: bump minor
                [major, minor + 1, 0]
              end

      [lower, upper]
    end

    # Returns bounds for caret (^) range per semver spec:
    # ^X.Y.Z where X > 0 → >=X.Y.Z <(X+1).0.0
    # ^0.Y.Z where Y > 0 → >=0.Y.Z <0.(Y+1).0
    # ^0.0.Z → >=0.0.Z <0.0.(Z+1)
    def self.semver_caret_bounds(value)
      major, minor, patch = parse_semver(value)
      lower = [major, minor, patch]

      upper = if major.positive?
                [major + 1, 0, 0]
              elsif minor.positive?
                [0, minor + 1, 0]
              else
                [0, 0, patch + 1]
              end

      [lower, upper]
    end

    # Returns bounds for wildcard (*) range:
    # X.* or X → >=X.0.0 <(X+1).0.0
    # X.Y.* → >=X.Y.0 <X.(Y+1).0
    def self.semver_wildcard_bounds(value)
      cleaned = value.to_s.strip.sub(/^[vV]/, '').gsub('*', '').chomp('.')
      parts = cleaned.split('.').reject(&:empty?)

      if parts.empty?
        raise InconclusiveMatchError.new('Invalid semver wildcard format',
                                         reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end

      numeric = parts.map do |part|
        parse_semver_numeric(part)
      rescue InconclusiveMatchError
        raise InconclusiveMatchError.new('Invalid semver wildcard format',
                                         reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end

      major = numeric[0]
      case numeric.length
      when 1
        [[major, 0, 0], [major + 1, 0, 0]]
      when 2
        minor = numeric[1]
        [[major, minor, 0], [major, minor + 1, 0]]
      else
        minor = numeric[1]
        patch = numeric[2]
        [[major, minor, patch], [major, minor, patch + 1]]
      end
    end

    # Service legacy classifies the entire filter, not individual array members.
    def self.boolean_like?(value)
      case value
      when true, false then true
      when String then %w[true false].include?(value.downcase)
      when Array then value.all? { |member| boolean_like?(member) }
      else false
      end
    end

    def self.legacy_truthy?(value)
      case value
      when true then true
      when String then value.downcase == 'true'
      when Array then value.all? { |member| legacy_truthy?(member) }
      else false
      end
    end

    def self.sorted_composite(value)
      case value
      when Hash
        value.transform_keys(&:to_s).sort.to_h.transform_values { |member| sorted_composite(member) }
      when Array
        value.map { |member| sorted_composite(member) }
      else
        value
      end
    end

    def self.property_string(value)
      # Keep numeric normalization unchanged; null and composites need JSON rather
      # than Ruby's nil.to_s / Array#to_s representations.
      case value
      when nil, Array, Hash then JSON.generate(sorted_composite(value))
      else value.to_s
      end.downcase
    end

    def self.string_operand(value)
      value.nil? ? 'null' : value.to_s
    end
    private_class_method :string_operand

    def self.exact_property_match?(filter, value, property_matching_version)
      return legacy_truthy?(filter) == legacy_truthy?(value) if property_matching_version != 2 && boolean_like?(filter)
      return legacy_truthy?(value) if filter.is_a?(Array) && filter.empty?

      if filter.is_a?(Array)
        filter.any? { |member| property_string(member) == property_string(value) }
      else
        property_string(filter) == property_string(value)
      end
    end

    private_class_method :boolean_like?, :legacy_truthy?, :sorted_composite, :property_string, :exact_property_match?

    def self.match_property(property, property_values, cohort_properties = {}, property_matching_version: 1)
      # only looks for matches where key exists in property_values

      PostHog::Utils.symbolize_keys! property
      PostHog::Utils.symbolize_keys! property_values

      # Handle cohort properties
      if extract_value(property, :type) == 'cohort'
        return match_cohort(property, property_values, cohort_properties,
                            property_matching_version: property_matching_version)
      end

      begin
        match_property_value(property, property_values, property_matching_version)
      rescue InconclusiveMatchError => e
        # An unusable filter outranks missing context, so check the filter before blaming the context.
        assert_filter_supported(property) if e.reason == UnresolvedFlagReason::MISSING_CONTEXT
        raise
      end
    end

    def self.match_property_value(property, property_values, property_matching_version)
      key = property[:key].to_sym
      value = property[:value]
      operator = property[:operator] || 'exact'

      if !property_values.key?(key)
        raise InconclusiveMatchError.new("Property #{key} not found in property_values",
                                         reason: UnresolvedFlagReason::MISSING_CONTEXT)
      elsif operator == 'is_not_set'
        return false
      end

      override_value = property_values[key]

      case operator
      when 'exact', 'is_not'
        matches = exact_property_match?(value, override_value, property_matching_version)
        operator == 'exact' ? matches : !matches
      when 'is_set'
        property_values.key?(key)
      when 'icontains'
        string_operand(override_value).downcase(:ascii).include?(value.to_s.downcase(:ascii))
      when 'not_icontains'
        !string_operand(override_value).downcase(:ascii).include?(value.to_s.downcase(:ascii))
      when 'starts_with'
        string_operand(override_value).downcase(:ascii).start_with?(value.to_s.downcase(:ascii))
      when 'not_starts_with'
        !string_operand(override_value).downcase(:ascii).start_with?(value.to_s.downcase(:ascii))
      when 'ends_with'
        string_operand(override_value).downcase(:ascii).end_with?(value.to_s.downcase(:ascii))
      when 'not_ends_with'
        !string_operand(override_value).downcase(:ascii).end_with?(value.to_s.downcase(:ascii))
      when *REGEX_OPERATORS
        matched = match_regex(value.to_s, string_operand(override_value))
        return false if matched.nil?

        operator == 'regex' ? matched : !matched
      when *NUMERIC_OPERATORS
        parsed_value = parse_numeric_filter(value)
        parsed_override = parse_finite_number(override_value)
        return false if parsed_override.nil?

        compare(parsed_override, parsed_value, operator)
      when *DATE_OPERATORS
        # Parses the filter before the context, so a bad filter reports unsupported_definition even
        # when the context value is bad too.
        parsed_date = parse_date_filter(value)
        override_date = PostHog::Utils.convert_to_datetime(override_value.to_s,
                                                           reason: UnresolvedFlagReason::MISSING_CONTEXT)

        if operator == 'is_date_before'
          override_date < parsed_date
        elsif operator == 'is_date_after'
          override_date > parsed_date
        end
      when *SEMVER_COMPARISON_OPERATORS
        flag_parsed = parse_semver(value, reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
        override_parsed = parse_semver(override_value, reason: UnresolvedFlagReason::MISSING_CONTEXT)

        case operator
        when 'semver_eq'
          override_parsed == flag_parsed
        when 'semver_neq'
          override_parsed != flag_parsed
        when 'semver_gt'
          (override_parsed <=> flag_parsed) == 1
        when 'semver_gte'
          (override_parsed <=> flag_parsed) >= 0
        when 'semver_lt'
          (override_parsed <=> flag_parsed) == -1
        when 'semver_lte'
          (override_parsed <=> flag_parsed) <= 0
        end
      when 'semver_tilde'
        lower, upper = semver_tilde_bounds(value)
        override_parsed = parse_semver(override_value, reason: UnresolvedFlagReason::MISSING_CONTEXT)
        (override_parsed <=> lower) >= 0 && (override_parsed <=> upper) == -1
      when 'semver_caret'
        lower, upper = semver_caret_bounds(value)
        override_parsed = parse_semver(override_value, reason: UnresolvedFlagReason::MISSING_CONTEXT)
        (override_parsed <=> lower) >= 0 && (override_parsed <=> upper) == -1
      when 'semver_wildcard'
        lower, upper = semver_wildcard_bounds(value)
        override_parsed = parse_semver(override_value, reason: UnresolvedFlagReason::MISSING_CONTEXT)
        (override_parsed <=> lower) >= 0 && (override_parsed <=> upper) == -1
      else
        raise InconclusiveMatchError.new("Unknown operator: #{operator}",
                                         reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end
    end
    private_class_method :match_property_value

    # Raises an unsupported_definition error when local evaluation cannot use the filter, whatever
    # the call passes: an unknown operator, or a filter value that the operator cannot parse.
    def self.assert_filter_supported(property)
      value = property[:value]
      case property[:operator] || 'exact'
      when 'exact', 'is_not', 'is_set', 'is_not_set', 'icontains', 'not_icontains', 'starts_with',
           'not_starts_with', 'ends_with', 'not_ends_with'
        nil
      when *REGEX_OPERATORS
        # An empty input is the most portable one, so this raises only for a pattern that needs the
        # server whatever the value. Compile without matching, so a server-supplied pattern never runs
        # while definitions load.
        pattern = value.to_s
        compile_regex(pattern, '') unless pattern.empty?
      when *NUMERIC_OPERATORS
        parse_numeric_filter(value)
      when *DATE_OPERATORS
        parse_date_filter(value)
      when *SEMVER_COMPARISON_OPERATORS
        parse_semver(value, reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      when 'semver_tilde'
        semver_tilde_bounds(value)
      when 'semver_caret'
        semver_caret_bounds(value)
      when 'semver_wildcard'
        semver_wildcard_bounds(value)
      else
        raise InconclusiveMatchError.new("Unknown operator: #{property[:operator]}",
                                         reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end
    end

    def self.parse_numeric_filter(value)
      parsed_value = parse_finite_number(value)
      if parsed_value.nil?
        raise InconclusiveMatchError.new('Invalid numeric condition',
                                         reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end

      parsed_value
    end
    private_class_method :parse_numeric_filter

    def self.parse_date_filter(value)
      parsed_date = relative_date_parse_for_feature_flag_matching(value.to_s) ||
                    PostHog::Utils.convert_to_datetime(value.to_s,
                                                       reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      return parsed_date if parsed_date

      raise InconclusiveMatchError.new('Invalid date format', reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
    end
    private_class_method :parse_date_filter

    def self.match_regex(pattern, value)
      return true if pattern.empty?

      regex = compile_regex(pattern, value)
      return nil if regex.nil?

      !regex.match(value).nil?
    rescue InconclusiveMatchError
      raise
    rescue StandardError
      raise InconclusiveMatchError.new('Regex execution requires server evaluation',
                                       reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
    end
    private_class_method :match_regex

    # Returns nil for a pattern that Ruby cannot compile.
    def self.compile_regex(pattern, value)
      unless portable_regex?(pattern, value)
        raise InconclusiveMatchError.new('Regex compatibility requires server evaluation',
                                         reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end

      Regexp.new(pattern)
    rescue RegexpError => e
      # Ruby's repeat-count limit is smaller than the service's syntax limit.
      if e.message.include?('too big')
        raise InconclusiveMatchError.new('Regex compilation requires server evaluation',
                                         reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end

      nil
    rescue InconclusiveMatchError
      raise
    rescue StandardError
      # For example, a pattern with an invalid byte sequence.
      raise InconclusiveMatchError.new('Regex compatibility requires server evaluation',
                                       reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
    end
    private_class_method :compile_regex

    # Native compilation alone cannot establish compatibility with the flags service's Rust engine.
    # Keep ordinary scalar matching local, but defer engine-specific syntax and backtracking assertions.
    def self.portable_regex?(pattern, value)
      # Ruby string offsets repeatedly traverse multibyte prefixes; tokenize once for constant-time lookahead.
      characters = pattern.chars
      ascii_input = value.ascii_only?
      newline_input = value.include?("\n")
      class_start = nil
      previous_token = nil
      index = 0
      while index < characters.length
        character = characters[index]
        if character == '\\'
          index += 1
          escaped = characters[index]
          break if escaped.nil?

          if escaped == 'x'
            hex = characters[index + 1, 2]&.join
            return false unless hex&.match?(/\A[0-9a-fA-F]{2}\z/) && hex.to_i(16) < 128

            index += 2
          elsif 'dDsSwW'.include?(escaped)
            # Ruby shorthand classes are ASCII-oriented, unlike the service's Unicode classes.
            return false unless ascii_input
          elsif class_start.nil?
            return false if 'bB'.include?(escaped) # Even short ASCII inputs can exceed the service's boundary budget.
            return false unless 'Azfnrtv'.include?(escaped) || escaped.match?(/[\x20-\x2f:;=?@\x5b-\x60\x7b-\x7e]/)
          else
            return false unless 'bfnrtv\\.^$|?*+(){}[]-'.include?(escaped)
          end
          previous_token = class_start.nil? && %w[A z].include?(escaped) ? :assertion : :literal
        elsif character == '['
          return false unless class_start.nil?

          class_start = index
        elsif character == ']' && class_start
          content_start = class_start + (characters[class_start + 1] == '^' ? 2 : 1)
          return false if index == content_start

          class_start = nil
          previous_token = :literal
        elsif class_start
          return false if %w[&& -- ~~].include?(characters[index, 2].join)
        else
          token = character
          if character == '(' && characters[index + 1] == '?'
            return false unless characters[index + 2] == ':'

            index += 2
          elsif character == '{'
            repetition_end = regex_repetition_end(characters, index)
            return false unless repetition_end && ![nil, '|', '('].include?(previous_token)
            return false if %i[assertion empty_group repetition lazy_repetition
                               bounded_repetition].include?(previous_token)

            index = repetition_end
            token = :bounded_repetition
          elsif '*+?'.include?(character)
            # A leading quantifier is invalid in both engines, regardless of the remaining syntax.
            return true if [nil, '|', '('].include?(previous_token)
            return false if %i[assertion empty_group].include?(previous_token)

            repeated = %i[repetition lazy_repetition bounded_repetition].include?(previous_token)
            return false if repeated && !(character == '?' && previous_token == :repetition)

            token = :repetition
            token = :lazy_repetition if repeated
          elsif '^$'.include?(character)
            # Ruby ^/$ are line anchors even without a multiline option; Rust's defaults are absolute.
            return false if newline_input

            token = :assertion
          elsif character == ')' && ['(', :empty_group].include?(previous_token)
            token = :empty_group
          end
          previous_token = token
        end
        index += 1
      end
      true
    end
    private_class_method :portable_regex?

    def self.regex_repetition_end(characters, index)
      index += 1
      return nil unless characters[index]&.match?(/\A[0-9]\z/)

      count = 0
      comma = false
      while index < characters.length
        character = characters[index]
        digit = character.ord - 48
        if digit.between?(0, 9)
          count = (count * 10) + digit
          return nil if count > 0xffffffff
        elsif character == ',' && !comma
          comma = true
          count = 0
        elsif character == '}'
          return index
        else
          return nil
        end
        index += 1
      end
      nil
    end
    private_class_method :regex_repetition_end

    def self.match_cohort(property, property_values, cohort_properties, property_matching_version: 1)
      # Cohort properties are in the form of property groups like this:
      # {
      #   "cohort_id" => {
      #     "type" => "AND|OR",
      #     "values" => [{
      #        "key" => "property_name", "value" => "property_value"
      #     }]
      #   }
      # }
      cohort_id = extract_value(property, :value).to_s
      property_group = find_cohort_property(cohort_properties, cohort_id)

      unless property_group
        raise RequiresServerEvaluation.new(
          "cohort #{cohort_id} not found in local cohorts - likely a static cohort that requires server evaluation",
          reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        )
      end

      match_property_group(property_group, property_values, cohort_properties,
                           property_matching_version: property_matching_version)
    end

    def self.match_property_group(property_group, property_values, cohort_properties, property_matching_version: 1)
      return true if property_group.nil? || property_group.empty?

      group_type = extract_value(property_group, :type)
      properties = extract_value(property_group, :values)

      return true if properties.nil? || properties.empty?

      if nested_property_group?(properties)
        property_group_items_match?(properties, group_type) do |group|
          match_property_group(group, property_values, cohort_properties,
                               property_matching_version: property_matching_version)
        end
      else
        property_group_items_match?(properties, group_type) do |prop|
          PostHog::Utils.symbolize_keys!(prop)
          matches = match_property(prop, property_values, cohort_properties,
                                   property_matching_version: property_matching_version)
          prop[:negation] ? !matches : matches
        end
      end
    end

    def self.extract_value(hash, key)
      return nil unless hash.is_a?(Hash)

      hash[key] || hash[key.to_s]
    end

    def self.find_cohort_property(cohort_properties, cohort_id)
      return nil unless cohort_properties.is_a?(Hash)

      cohort_properties[cohort_id] || cohort_properties[cohort_id.to_sym]
    end

    def self.nested_property_group?(properties)
      return false unless properties&.any?

      first_property = properties[0]
      return false unless first_property.is_a?(Hash)

      first_property.key?(:values) || first_property.key?('values')
    end

    # Combines the items of a cohort property group with AND or OR. The block evaluates one item.
    # RequiresServerEvaluation is not an InconclusiveMatchError, so it propagates at once.
    def self.property_group_items_match?(items, group_type)
      unless %w[AND OR].include?(group_type)
        raise InconclusiveMatchError.new("Unknown property group type: #{group_type}",
                                         reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end

      inconclusive_reason = nil
      items.each do |item|
        matches = yield(item)
        if group_type == 'AND'
          return false unless matches
        elsif matches
          return true
        end
      rescue InconclusiveMatchError => e
        PostHog::Logging.logger&.debug("Failed to compute property #{item} locally: #{e}")
        inconclusive_reason = pick_unresolved_reason(inconclusive_reason, e.reason)
      end

      unless inconclusive_reason.nil?
        raise InconclusiveMatchError.new("can't match cohort without a given cohort property value",
                                         reason: inconclusive_reason)
      end

      group_type == 'AND'
    end

    # Evaluates a flag dependency property according to the dependency chain algorithm.
    #
    # @param property [Hash] Flag property with type="flag" and dependency_chain
    # @param evaluation_cache [Hash] Cache for storing evaluation results
    # @param distinct_id [String] The distinct ID being evaluated
    # @param properties [Hash] Person properties for evaluation
    # @param cohort_properties [Hash] Cohort properties for evaluation
    # @return [Boolean] True if all dependencies in the chain evaluate to true, false otherwise
    def evaluate_flag_dependency(property, evaluation_cache, distinct_id, properties, cohort_properties,
                                 snapshot: _evaluation_snapshot)
      if snapshot[:flags_by_key].nil? || evaluation_cache.nil?
        # Cannot evaluate flag dependencies without required context
        raise InconclusiveMatchError.new(
          "Cannot evaluate flag dependency on '#{property[:key] || 'unknown'}' " \
          'without feature flags loaded or evaluation_cache',
          reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        )
      end

      # A dependency with no definition outranks one that is only inconclusive, so this checks the whole
      # chain before evaluating any of it. Nothing is cached for it, so a later lookup reports the same.
      definition_error = FeatureFlagsPoller.flag_dependency_definition_error(property, snapshot[:flags_by_key])
      unless definition_error.nil?
        raise InconclusiveMatchError.new(definition_error, reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end

      dependency_chain = property[:dependency_chain]

      # Evaluate all dependencies in the chain order
      dependency_chain.each do |dep_flag_key|
        unless evaluation_cache.key?(dep_flag_key)
          # Need to evaluate this dependency first
          dep_flag = snapshot[:flags_by_key][dep_flag_key]
          if !dep_flag[:active]
            # Check if the flag is active (same check as in _compute_flag_locally)
            evaluation_cache[dep_flag_key] = false
          elsif dep_flag[:ensure_experience_continuity]
            evaluation_cache[dep_flag_key] = nil
            raise InconclusiveMatchError.new(
              "Cannot evaluate flag dependency '#{dep_flag_key}' - flag has experience continuity enabled",
              reason: UnresolvedFlagReason::UNRESOLVED_DEPENDENCY
            )
          else
            # Recursively evaluate the dependency using existing instance method
            begin
              dep_result = match_feature_flag_properties(
                dep_flag,
                distinct_id,
                properties,
                evaluation_cache,
                cohort_properties,
                snapshot: snapshot
              )
              evaluation_cache[dep_flag_key] = dep_result
            rescue RequiresServerEvaluation => e
              # The dependent flag needs the server too. Nothing is cached, so a later lookup of this
              # dependency also requires the server instead of reading it as merely inconclusive.
              raise RequiresServerEvaluation.new("Cannot evaluate flag dependency '#{dep_flag_key}': #{e.message}",
                                                 reason: UnresolvedFlagReason::UNRESOLVED_DEPENDENCY)
            rescue InconclusiveMatchError => e
              # If we can't evaluate a dependency, store nil and propagate the error
              evaluation_cache[dep_flag_key] = nil
              raise InconclusiveMatchError.new("Cannot evaluate flag dependency '#{dep_flag_key}': #{e.message}",
                                               reason: UnresolvedFlagReason::UNRESOLVED_DEPENDENCY)
            end
          end
        end

        # Check the cached result
        cached_result = evaluation_cache[dep_flag_key]
        if cached_result.nil?
          # Previously inconclusive - raise error again
          raise InconclusiveMatchError.new("Flag dependency '#{dep_flag_key}' was previously inconclusive",
                                           reason: UnresolvedFlagReason::UNRESOLVED_DEPENDENCY)
        elsif !cached_result
          # Definitive False result - dependency failed
          return false
        end
      end

      # Get the expected value of the immediate dependency and the actual value
      expected_value = property[:value]
      # The flag we want to evaluate is defined by :key which should ALSO be the last key in the dependency chain
      actual_value = evaluation_cache[property[:key]]

      self.class.matches_dependency_value(expected_value, actual_value)
    end

    def self.matches_dependency_value(expected_value, actual_value)
      # Check if the actual flag value matches the expected dependency value.
      #
      # - String variant case: check for exact match or boolean true
      # - Boolean case: must match expected boolean value
      #
      # @param expected_value [Object] The expected value from the property
      # @param actual_value [Object] The actual value returned by the flag evaluation
      # @return [Boolean] True if the values match according to flag dependency rules

      # String variant case - check for exact match or boolean true
      if actual_value.is_a?(String) && !actual_value.empty?
        if expected_value.is_a?(TrueClass) || expected_value.is_a?(FalseClass)
          # Any variant matches boolean true
          return expected_value
        elsif expected_value.is_a?(String)
          # variants are case-sensitive, hence our comparison is too
          return actual_value == expected_value
        else
          return false
        end

      # Boolean case - must match expected boolean value
      elsif actual_value.is_a?(TrueClass) || actual_value.is_a?(FalseClass)
        return actual_value == expected_value if expected_value.is_a?(TrueClass) || expected_value.is_a?(FalseClass)
      end

      # Default case
      false
    end

    # The unresolved reason that comes from the flag's definition alone, so it is known when
    # definitions load. Matches the reason local evaluation reports for the same cause.
    def self.definition_unresolved_reason(flag, flags_by_key, cohorts, group_type_mapping)
      return nil unless flag[:active]
      return UnresolvedFlagReason::EXPERIENCE_CONTINUITY if flag[:ensure_experience_continuity]

      flag_filters = flag[:filters] || {}
      aggregation = flag_filters[:aggregation_group_type_index]
      if !aggregation.nil? && group_type_mapping[aggregation.to_s.to_sym].nil?
        return UnresolvedFlagReason::UNSUPPORTED_DEFINITION
      end

      unsupported = (flag_filters[:groups] || []).any? do |condition|
        (condition[:properties] || []).any? do |property|
          unsupported_property?(property, flags_by_key, cohorts, Set.new)
        end
      end
      unsupported ? UnresolvedFlagReason::UNSUPPORTED_DEFINITION : nil
    end

    # Why a flag dependency filter can never evaluate locally, whatever the call passes, or nil.
    # Evaluation and the load-time warning both use it, so the warning matches the reason evaluation reports.
    def self.flag_dependency_definition_error(property, flags_by_key)
      operator = property[:operator]
      return "Operator #{operator} not supported for flag dependencies" if operator != 'flag_evaluates_to'

      key = property[:key] || 'unknown'
      dependency_chain = property[:dependency_chain]
      unless property.key?(:dependency_chain)
        return "Flag dependency property for '#{key}' is missing required 'dependency_chain' field"
      end
      unless dependency_chain.is_a?(Array)
        return "Flag dependency property for '#{key}' has an invalid 'dependency_chain' field"
      end
      return "Circular dependency detected for flag '#{key}'" if dependency_chain.empty?

      missing_dependency = dependency_chain.find { |dep_flag_key| flags_by_key[dep_flag_key].nil? }
      return nil if missing_dependency.nil?

      "Cannot evaluate flag dependency '#{missing_dependency}' - flag not found in local flags"
    end

    def self.unsupported_property?(property, flags_by_key, cohorts, visited_cohort_ids)
      case property[:type]
      when 'flag'
        !flag_dependency_definition_error(property, flags_by_key).nil?
      when 'cohort'
        cohort_id = property[:value].to_s
        property_group = find_cohort_property(cohorts, cohort_id)
        return true if property_group.nil?
        return false unless visited_cohort_ids.add?(cohort_id)

        unsupported_property_group?(property_group, flags_by_key, cohorts, visited_cohort_ids)
      else
        unsupported_filter?(property)
      end
    end

    def self.unsupported_property_group?(property_group, flags_by_key, cohorts, visited_cohort_ids)
      properties = extract_value(property_group, :values)
      return false if properties.nil? || properties.empty?
      return true unless %w[AND OR].include?(extract_value(property_group, :type))

      if nested_property_group?(properties)
        return properties.any? do |group|
          unsupported_property_group?(group, flags_by_key, cohorts, visited_cohort_ids)
        end
      end

      properties.any? do |property|
        filter = PostHog::Utils.symbolize_keys(property)
        if filter[:type] == 'cohort'
          unsupported_property?(filter, flags_by_key, cohorts, visited_cohort_ids)
        else
          # Like evaluation, a cohort group checks a flag filter as an ordinary property.
          unsupported_filter?(filter)
        end
      end
    end

    def self.unsupported_filter?(property)
      assert_filter_supported(property)
      false
    rescue InconclusiveMatchError
      true
    end

    private_class_method :extract_value, :find_cohort_property, :nested_property_group?,
                         :property_group_items_match?, :assert_filter_supported,
                         :unsupported_property?, :unsupported_property_group?, :unsupported_filter?

    # Publish/capture all matching state together so a poll cannot switch semantics
    # (or dependency/cohort definitions) halfway through one local evaluation.
    def _evaluation_snapshot
      @definition_snapshot.value
    end

    def _compute_flag_locally(flag, distinct_id, groups = {}, person_properties = {}, group_properties = {},
                              snapshot: _evaluation_snapshot)
      # An inactive flag is false whatever its experience continuity setting.
      return false unless flag[:active]

      if flag[:ensure_experience_continuity]
        raise RequiresServerEvaluation.new('Flag has experience continuity enabled',
                                           reason: UnresolvedFlagReason::EXPERIENCE_CONTINUITY)
      end

      # Create evaluation cache for flag dependencies
      evaluation_cache = {}

      flag_filters = flag[:filters] || {}

      aggregation_group_type_index = flag_filters[:aggregation_group_type_index]
      if aggregation_group_type_index.nil?
        local_person_properties = person_properties || {}
        unless local_person_properties.key?(:distinct_id) || local_person_properties.key?('distinct_id')
          local_person_properties = local_person_properties.merge(distinct_id: distinct_id)
        end

        return match_feature_flag_properties(flag, distinct_id, local_person_properties, evaluation_cache,
                                             snapshot[:cohorts], groups: groups, group_properties: group_properties,
                                                                 snapshot: snapshot)
      end

      group_name = snapshot[:group_type_mapping][aggregation_group_type_index.to_s.to_sym]

      if group_name.nil?
        logger.warn(
          "[FEATURE FLAGS] Unknown group type index #{aggregation_group_type_index} for feature flag #{flag[:key]}"
        )
        # failover to `/flags/`
        raise InconclusiveMatchError.new('Flag has unknown group type index',
                                         reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end

      group_name_symbol = group_name.to_sym

      unless groups.key?(group_name_symbol)
        # Group flags are never enabled if appropriate `groups` aren't passed in
        # don't failover to `/flags/`, since response will be the same
        logger.warn "[FEATURE FLAGS] Can't compute group feature flag: #{flag[:key]} without group names passed in"
        return false
      end

      focused_group_properties = group_properties[group_name_symbol]
      match_feature_flag_properties(flag, groups[group_name_symbol], focused_group_properties, evaluation_cache,
                                    snapshot[:cohorts], groups: groups, group_properties: group_properties,
                                                        snapshot: snapshot)
    end

    def _compute_flag_payload_locally(key, match_value, snapshot: _evaluation_snapshot)
      return nil if snapshot[:flags_by_key].nil?

      key = key.to_s
      response = nil
      if [true, false].include? match_value
        response = snapshot[:flags_by_key].dig(key, :filters, :payloads, match_value.to_s.to_sym)
      elsif match_value.is_a? String
        response = snapshot[:flags_by_key].dig(key, :filters, :payloads, match_value.to_sym)
      end
      response
    end

    def match_feature_flag_properties(flag, distinct_id, properties, evaluation_cache, cohort_properties = {},
                                      groups: {}, group_properties: {}, snapshot: _evaluation_snapshot)
      flag_filters = flag[:filters] || {}

      # Holdouts precede release conditions: a held-out identifier is excluded from
      # the flag's targeting entirely rather than bucketed into one of its variants.
      # The per-condition aggregation handled below never changes holdout membership,
      # so this uses the flag-level bucketing identity the caller resolved.
      holdout_variant = holdout_variant_for(flag_filters[:holdout], distinct_id)
      return holdout_variant unless holdout_variant.nil?

      flag_conditions = flag_filters[:groups] || []
      flag_aggregation = flag_filters[:aggregation_group_type_index]
      early_exit = flag_filters[:early_exit] == true
      inconclusive_reason = nil
      result = nil

      # NOTE: This NEEDS to be `each` because `each_key` breaks
      flag_conditions.each do |condition|
        # Per-condition aggregation overrides only when the condition explicitly
        # sets its own aggregation_group_type_index (mixed targeting). When absent,
        # use the properties/bucketing already resolved by the caller.
        condition_aggregation = condition.fetch(:aggregation_group_type_index, flag_aggregation)

        effective_properties = properties
        effective_bucketing = distinct_id

        # Mixed-override path: condition-level aggregation differs from flag-level.
        # This assumes flag-level aggregation is nil for mixed flags.
        if condition_aggregation != flag_aggregation
          if condition_aggregation.nil?
            # Person condition under a mixed flag — caller already passed person props/bucketing.
          else
            group_name = snapshot[:group_type_mapping][condition_aggregation.to_s.to_sym]
            if group_name.nil? || !groups.key?(group_name.to_sym)
              logger.debug do
                "[FEATURE FLAGS] Skipping group condition for flag '#{flag[:key]}': " \
                  "group type index #{condition_aggregation} not available"
              end
              next
            end
            unless group_properties.key?(group_name.to_sym)
              inconclusive_reason = FeatureFlagsPoller.pick_unresolved_reason(
                inconclusive_reason, UnresolvedFlagReason::MISSING_CONTEXT
              )
              next
            end
            effective_properties = group_properties[group_name.to_sym]
            effective_bucketing = groups[group_name.to_sym]
          end
        end

        case condition_match_outcome(flag, effective_bucketing, condition, effective_properties, evaluation_cache,
                                     cohort_properties, snapshot: snapshot)
        when :match
          variant_override = condition[:variant]
          flag_multivariate = flag_filters[:multivariate] || {}
          flag_variants = flag_multivariate[:variants] || []
          variant = if flag_variants.map { |variant| variant[:key] }.include?(condition[:variant])
                      variant_override
                    else
                      get_matching_variant(flag, effective_bucketing)
                    end
          result = variant || true
          break
        when :out_of_rollout_bound
          break if early_exit
        end
      rescue RequiresServerEvaluation => e
        # Static cohort or other missing server-side data - must fallback to API. Evaluation stops here and
        # skips filters it did not reach, so the flag's definition still counts toward the reason.
        reason = FeatureFlagsPoller.pick_unresolved_reason(inconclusive_reason, e.reason)
        definition_reason = _definition_unresolved_reason(flag, snapshot)
        reason = FeatureFlagsPoller.pick_unresolved_reason(reason, definition_reason) unless definition_reason.nil?
        raise RequiresServerEvaluation.new(e.message, reason: reason)
      rescue InconclusiveMatchError => e
        # Evaluation error (bad regex, invalid date, missing property, etc.)
        # Track that we had an inconclusive match, but try other conditions
        inconclusive_reason = FeatureFlagsPoller.pick_unresolved_reason(inconclusive_reason, e.reason)
      end

      if !result.nil?
        return result
      elsif !inconclusive_reason.nil?
        raise InconclusiveMatchError.new("Can't determine if feature flag is enabled or not with given properties",
                                         reason: inconclusive_reason)
      end

      # We can only return False when all conditions are False
      false
    end

    def _definition_unresolved_reason(flag, snapshot)
      self.class.definition_unresolved_reason(flag, snapshot[:flags_by_key] || {}, snapshot[:cohorts],
                                              snapshot[:group_type_mapping])
    rescue StandardError
      # A malformed definition must not stop the fallback to the server.
      nil
    end

    def condition_match(flag, distinct_id, condition, properties, evaluation_cache, cohort_properties = {},
                        snapshot: _evaluation_snapshot)
      condition_match_outcome(flag, distinct_id, condition, properties, evaluation_cache,
                              cohort_properties, snapshot: snapshot) == :match
    end

    # Evaluates a single condition group and returns a tri-state outcome:
    #   :match                 - property filters matched AND the rollout included the user
    #   :no_match              - a property filter did NOT match
    #   :out_of_rollout_bound  - property filters matched (or there were none) but the
    #                            rollout percentage excluded the user
    # Distinguishing :no_match from :out_of_rollout_bound lets the caller implement the
    # early_exit behavior (mirrors the server-side Rust evaluation engine).
    def condition_match_outcome(flag, distinct_id, condition, properties, evaluation_cache, cohort_properties = {},
                                snapshot: _evaluation_snapshot)
      rollout_percentage = condition[:rollout_percentage]

      unless (condition[:properties] || []).empty?
        # Filters in a condition have no defined order, so an inconclusive filter does not stop the
        # loop: a later filter can still rule the condition out or carry a higher-precedence reason.
        inconclusive_reason = nil
        server_evaluation_error = nil
        condition[:properties].each do |prop|
          matches =
            if prop[:type] == 'flag'
              evaluate_flag_dependency(prop, evaluation_cache, distinct_id, properties, cohort_properties,
                                       snapshot: snapshot)
            else
              FeatureFlagsPoller.match_property(prop, properties, cohort_properties,
                                                property_matching_version: snapshot[:property_matching_version])
            end
          return :no_match unless matches
        rescue RequiresServerEvaluation => e
          # Fall back to the server only when this is the first filter that could not be checked, as
          # when the loop stopped there. After another inconclusive filter, later conditions must still
          # be able to resolve the flag locally.
          server_evaluation_error ||= e if inconclusive_reason.nil?
          inconclusive_reason = FeatureFlagsPoller.pick_unresolved_reason(inconclusive_reason, e.reason)
        rescue InconclusiveMatchError => e
          inconclusive_reason = FeatureFlagsPoller.pick_unresolved_reason(inconclusive_reason, e.reason)
        rescue StandardError
          raise if inconclusive_reason.nil?

          # The condition is already inconclusive, so an unexpected error in a later filter must not
          # fail the whole flag. Later conditions can still resolve it.
          break
        end

        # Raise the original error type: match_feature_flag_properties stops at it and falls back to the
        # server instead of trying later conditions. A later filter can still carry a higher-precedence reason.
        unless server_evaluation_error.nil?
          raise RequiresServerEvaluation.new(server_evaluation_error.message, reason: inconclusive_reason)
        end
        unless inconclusive_reason.nil?
          raise InconclusiveMatchError.new("Can't determine if a condition of flag #{flag[:key]} matches",
                                           reason: inconclusive_reason)
        end

        return :match if rollout_percentage.nil?
      end

      if !rollout_percentage.nil? && (_hash(flag[:key], distinct_id) > (rollout_percentage.to_f / 100))
        return :out_of_rollout_bound
      end

      :match
    end

    # This function takes a distinct_id and a feature flag key and returns a float between 0 and 1.
    # Given the same distinct_id and key, it'll always return the same float. These floats are
    # uniformly distributed between 0 and 1, so if we want to show this feature to 20% of traffic
    # we can do _hash(key, distinct_id) < 0.2
    def _hash(key, distinct_id, salt = '')
      hash_key = Digest::SHA1.hexdigest "#{key}.#{distinct_id}#{salt}"
      (Integer(hash_key[0..14], 16).to_f / 0xfffffffffffffff)
    end

    # An experiment holdout excludes an identifier from the flag's release conditions
    # entirely, resolving it to the synthetic variant "holdout-<id>". That variant does
    # not need to exist in `filters.multivariate.variants`. Returns nil when the flag has
    # no usable holdout or the identifier falls outside it, leaving ordinary evaluation
    # unchanged.
    def holdout_variant_for(holdout, bucketing_value)
      return nil unless holdout.is_a?(Hash)

      id = holdout[:id]
      exclusion_percentage = holdout[:exclusion_percentage]
      return nil if id.nil? || !exclusion_percentage.is_a?(Numeric)

      # The server clamps an out-of-range percentage rather than rejecting it, and treats
      # 100 as everyone without hashing, so a full holdout can't miss on a hash boundary.
      # Fractional percentages are kept as-is.
      percentage = exclusion_percentage.to_f.clamp(0, 100)
      return nil if percentage < 100 && _holdout_hash(bucketing_value) > (percentage / 100)

      "holdout-#{id}"
    end

    # Holdout membership hashes `holdout-<bucketing value>` with no separator, salt, flag
    # key or holdout id taking part, so one identity lands in the same holdout population
    # on every flag, the way the server buckets it. The dot-separated flag hash above
    # selects a different population and must not be reused here.
    def _holdout_hash(bucketing_value)
      hash_key = Digest::SHA1.hexdigest "holdout-#{bucketing_value}"
      (Integer(hash_key[0..14], 16).to_f / 0xfffffffffffffff)
    end

    def get_matching_variant(flag, distinct_id)
      hash_value = _hash(flag[:key], distinct_id, 'variant')
      matching_variant = variant_lookup_table(flag).find do |variant|
        hash_value >= variant[:value_min] and hash_value < variant[:value_max]
      end
      matching_variant.nil? ? nil : matching_variant[:key]
    end

    def variant_lookup_table(flag)
      lookup_table = []
      value_min = 0
      flag_filters = flag[:filters] || {}
      variants = flag_filters[:multivariate] || {}
      multivariates = variants[:variants] || []
      multivariates.each do |variant|
        value_max = value_min + (variant[:rollout_percentage].to_f / 100)
        lookup_table << { value_min: value_min, value_max: value_max, key: variant[:key] }
        value_min = value_max
      end
      lookup_table
    end

    def _load_feature_flags
      should_fetch = true

      if @flag_definition_cache_provider
        begin
          # Cache-only readers must not acquire or renew fetch leadership.
          should_fetch = @secret_key && @flag_definition_cache_provider.should_fetch_flag_definitions?
        rescue StandardError => e
          logger.error("[FEATURE FLAGS] Cache provider should_fetch error: #{e}")
          should_fetch = true
        end
      end

      unless should_fetch
        begin
          cached_data = @flag_definition_cache_provider.flag_definitions
          if cached_data
            unless cached_data.is_a?(Hash) && get_by_symbol_or_string_key(cached_data, 'flags').is_a?(Array)
              raise ArgumentError, 'Cached flag definitions must contain a flags array'
            end

            logger.debug '[FEATURE FLAGS] Using cached flag definitions from external cache'
            _apply_flag_definitions(cached_data)
            return
          elsif @feature_flags.empty?
            # Emergency fallback: cache empty and no flags loaded -> fetch from API
            should_fetch = true
          end
        rescue StandardError => e
          logger.error("[FEATURE FLAGS] Cache provider get error: #{e}")
          should_fetch = true
        end
      end

      _fetch_and_apply_flag_definitions if should_fetch
    end

    def _fetch_and_apply_flag_definitions
      unless @secret_key
        logger.warn '[FEATURE FLAGS] A secret_key is required to fetch flag definitions from PostHog'
        return
      end

      begin
        res = _request_feature_flag_definitions(etag: @flags_etag.value)
      rescue StandardError => e
        @on_error.call(-1, e.to_s)
        return
      end

      # Handle 304 Not Modified - flags haven't changed, skip processing
      # Only update ETag if the 304 response includes one
      if res[:not_modified]
        @flags_etag.value = res[:etag] if res[:etag]
        logger.debug '[FEATURE FLAGS] Flags not modified (304), using cached data'
        return
      end

      # Handle quota limits with 402 status
      if res.is_a?(Hash) && res[:status] == 402
        logger.warn(
          '[FEATURE FLAGS] Feature flags quota limit exceeded - unsetting all local flags. ' \
          'Learn more about billing limits at https://posthog.com/docs/billing/limits-alerts'
        )
        @flag_definitions_update_mutex.synchronize do
          definitions_were_loaded = definitions_loaded?
          @feature_flags = Concurrent::Array.new
          @feature_flags_by_key = {}
          @group_type_mapping = Concurrent::Hash.new
          @cohorts = Concurrent::Hash.new
          @flag_definitions_loaded_at.value = nil
          @minimal_flag_called_events = false
          @definition_snapshot.value = {
            flags: @feature_flags, flags_by_key: @feature_flags_by_key,
            group_type_mapping: @group_type_mapping, cohorts: @cohorts,
            minimal_flag_called_events: false, property_matching_version: 1
          }.freeze
          @loaded_flags_successfully_once.make_false
          @quota_limited.make_true
          @on_flag_definitions_updated&.call if definitions_were_loaded
        end
        return
      end

      if res.key?(:flags)
        # Only update ETag on successful responses with flag data
        @flags_etag.value = res[:etag]

        _apply_flag_definitions(res)
        _store_in_cache_provider
      else
        logger.debug "Failed to load feature flags: #{res}"
      end
    end

    def _store_in_cache_provider
      return unless @flag_definition_cache_provider

      begin
        snapshot = _evaluation_snapshot
        data = {
          flags: snapshot[:flags].to_a,
          group_type_mapping: snapshot[:group_type_mapping].to_h,
          cohorts: snapshot[:cohorts].to_h,
          minimal_flag_called_events: snapshot[:minimal_flag_called_events],
          property_matching_version: snapshot[:property_matching_version]
        }
        @flag_definition_cache_provider.on_flag_definitions_received(data)
      rescue StandardError => e
        logger.error("[FEATURE FLAGS] Cache provider store error: #{e}")
      end
    end

    def _apply_flag_definitions(data)
      flags = get_by_symbol_or_string_key(data, 'flags') || []
      group_type_mapping = get_by_symbol_or_string_key(data, 'group_type_mapping') || {}
      cohorts = get_by_symbol_or_string_key(data, 'cohorts') || {}
      minimal_flag_called_events = get_by_symbol_or_string_key(data, 'minimal_flag_called_events')

      property_matching_version = get_by_symbol_or_string_key(data, 'property_matching_version') || 1
      new_flags = Concurrent::Array.new(flags.map { |f| deep_symbolize_keys(f) })
      new_by_key = {}
      new_flags.each do |flag|
        new_by_key[flag[:key]] = flag unless flag[:key].nil?
      end
      new_group_type_mapping = Concurrent::Hash[deep_symbolize_keys(group_type_mapping)]
      new_cohorts = Concurrent::Hash[deep_symbolize_keys(cohorts)]
      unresolvable_flags = _unresolvable_flags(new_flags, new_by_key, new_cohorts, new_group_type_mapping)
      unwarned_flags = nil

      # A read of the new definitions must not record its event before the tracker reset.
      @flag_definitions_update_mutex.synchronize do
        @definition_snapshot.value = {
          flags: new_flags, flags_by_key: new_by_key,
          group_type_mapping: new_group_type_mapping, cohorts: new_cohorts,
          minimal_flag_called_events: minimal_flag_called_events == true,
          property_matching_version: property_matching_version
        }.freeze
        @feature_flags = new_flags
        @feature_flags_by_key = new_by_key
        @group_type_mapping = new_group_type_mapping
        @cohorts = new_cohorts
        @minimal_flag_called_events = minimal_flag_called_events == true
        @flag_definitions_loaded_at.value = (Time.now.to_f * 1000).to_i
        @loaded_flags_successfully_once.make_true if @loaded_flags_successfully_once.false?
        # Rebuilt from the current definitions, so a flag that is deleted or becomes resolvable is
        # forgotten and warns again if it later returns to an unresolvable definition.
        unwarned_flags = unresolvable_flags.reject { |key, entry| @warned_unresolvable_flags[key] == entry }
        @warned_unresolvable_flags = unresolvable_flags
        @on_flag_definitions_updated&.call
      end
      _warn_about_unresolvable_flags(unwarned_flags)
      logger.debug "Loaded #{new_flags.length} feature flags and #{new_cohorts.length} cohorts"
    end

    # Flag key => [reason, definition] for each flag that local evaluation never resolves. Hash#== compares
    # the definition by content and ignores key order, so a reordered copy does not warn again.
    def _unresolvable_flags(flags, flags_by_key, cohorts, group_type_mapping)
      flags.each_with_object({}) do |flag, unresolvable|
        reason = self.class.definition_unresolved_reason(flag, flags_by_key, cohorts, group_type_mapping)
        next if reason.nil? || flag[:key].nil?

        unresolvable[flag[:key]] = [reason, flag]
      rescue StandardError
        # Evaluation reports a definition this malformed when the flag is used.
        next
      end
    end

    def _warn_about_unresolvable_flags(unresolvable_flags)
      keys_by_reason = unresolvable_flags.keys.group_by { |key| unresolvable_flags[key].first }

      experience_continuity_keys = keys_by_reason[UnresolvedFlagReason::EXPERIENCE_CONTINUITY]
      if experience_continuity_keys
        logger.warn(
          "[FEATURE FLAGS] #{experience_continuity_keys.length} flag(s) have experience continuity enabled and " \
          "can't be evaluated locally (reason: #{UnresolvedFlagReason::EXPERIENCE_CONTINUITY}): " \
          "#{experience_continuity_keys.join(', ')}. Evaluating them makes a remote request, or leaves them " \
          'unresolved with only_evaluate_locally: true. To evaluate them locally, disable experience continuity ' \
          'on these flags in PostHog.'
        )
      end

      unsupported_definition_keys = keys_by_reason[UnresolvedFlagReason::UNSUPPORTED_DEFINITION]
      return unless unsupported_definition_keys

      logger.warn(
        "[FEATURE FLAGS] #{unsupported_definition_keys.length} flag(s) use something local evaluation doesn't " \
        'support, such as a static cohort, an unknown operator, a malformed value, or a missing or circular flag ' \
        "dependency (reason: #{UnresolvedFlagReason::UNSUPPORTED_DEFINITION}): " \
        "#{unsupported_definition_keys.join(', ')}. Evaluating them makes a remote request when evaluation " \
        'reaches that part, or leaves them unresolved with only_evaluate_locally: true. To evaluate them ' \
        'locally, change these flags in PostHog or upgrade posthog-ruby.'
      )
    end

    def _request_feature_flag_definitions(etag: nil)
      uri = URI("#{@host}/flags/definitions")
      uri.query = URI.encode_www_form([['token', @project_api_key], %w[send_cohorts true]])
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{@secret_key}"
      req['If-None-Match'] = etag if etag

      _request(uri, req, nil, include_etag: true)
    end

    def _request_feature_flag_evaluation(data = {})
      uri = URI("#{@host}/flags/?v=2")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      data['token'] = @project_api_key
      req.body = data.to_json

      _request(
        uri,
        req,
        @feature_flag_request_timeout_seconds,
        retry_status_codes: RETRYABLE_FLAGS_REQUEST_STATUS_CODES
      )
    end

    def _request_remote_config_payload(flag_key)
      uri = URI("#{@host}/api/projects/@current/feature_flags/#{flag_key}/remote_config")
      uri.query = URI.encode_www_form([['token', @project_api_key]])
      req = Net::HTTP::Get.new(uri)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = "Bearer #{@secret_key}"

      _request(uri, req, @feature_flag_request_timeout_seconds)
    end

    # Transient network errors that are safe to retry. Flag requests are
    # retry-safe (stateless reads and evaluations, no server-side mutation), so
    # a one-off blip (TCP retransmit, TLS jitter, an edge/proxy hiccup) should
    # be absorbed by a retry rather than surfaced to the caller.
    RETRYABLE_REQUEST_ERRORS = [
      Timeout::Error, # covers Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      Errno::ECONNRESET,
      EOFError
    ].freeze
    RETRYABLE_FLAGS_REQUEST_STATUS_CODES = [502, 504].freeze

    def _request(uri, request_object, timeout = nil, include_etag: false, retry_status_codes: [])
      request_object['User-Agent'] = @user_agent
      request_timeout = timeout || 10
      backoff_policy = nil
      attempts = 0

      loop do
        attempts += 1
        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == 'https',
          open_timeout: request_timeout,
          read_timeout: request_timeout,
          write_timeout: request_timeout
        ) do |http|
          res = http.request(request_object)
          status_code = res.code.to_i
          etag = include_etag ? res['ETag'] : nil

          if retry_status_codes.include?(status_code) && attempts <= @feature_flag_request_max_retries
            backoff_policy ||= BackoffPolicy.new
            interval = backoff_policy.next_interval.to_f / 1000
            logger.debug(
              "Retrying request to #{_mask_tokens_in_url(uri.to_s)} after HTTP #{status_code} (attempt #{attempts})"
            )
            sleep(interval)
            next
          end

          # Handle 304 Not Modified - return special response indicating no change
          if status_code == 304
            logger.debug("#{request_object.method} #{_mask_tokens_in_url(uri.to_s)} returned 304 Not Modified")
            return { not_modified: true, etag: etag, status: status_code }
          end

          # Parse response body to hash
          begin
            response = JSON.parse(res.body, symbolize_names: true)
            # Only add status (and etag if requested) if response is a hash
            extra_fields = { status: status_code }
            extra_fields[:etag] = etag if include_etag
            response = response.merge(extra_fields) if response.is_a?(Hash)
            return response
          rescue JSON::ParserError
            # Handle case when response isn't valid JSON
            error_response = { error: 'Invalid JSON response', body: res.body, status: status_code }
            error_response[:etag] = etag if include_etag
            return error_response
          end
        end
      rescue *RETRYABLE_REQUEST_ERRORS => e
        if attempts <= @feature_flag_request_max_retries
          backoff_policy ||= BackoffPolicy.new
          interval = backoff_policy.next_interval.to_f / 1000
          logger.debug("Retrying request to #{_mask_tokens_in_url(uri.to_s)} after #{e.class} (attempt #{attempts})")
          sleep(interval)
          next
        end
        logger.debug("Unable to complete request to #{_mask_tokens_in_url(uri.to_s)}")
        raise
      rescue Errno::EINVAL,
             Net::HTTPBadResponse,
             Net::HTTPHeaderSyntaxError,
             Net::ProtocolError
        logger.debug("Unable to complete request to #{_mask_tokens_in_url(uri.to_s)}")
        raise
      end
    end

    def _mask_tokens_in_url(url)
      url.gsub(/token=([^&]{10})[^&]*/, 'token=\1...')
    end
  end
end
