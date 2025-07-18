# frozen_string_literal: true

require 'concurrent'
require 'net/http'
require 'json'
require 'posthog/version'
require 'posthog/logging'
require 'posthog/feature_flag'
require 'digest'

module PostHog
  class InconclusiveMatchError < StandardError
  end

  class FeatureFlagsPoller
    include PostHog::Logging
    include PostHog::Utils

    def initialize(
      polling_interval,
      personal_api_key,
      project_api_key,
      host,
      feature_flag_request_timeout_seconds,
      on_error = nil
    )
      @polling_interval = polling_interval || 30
      @personal_api_key = personal_api_key
      @project_api_key = project_api_key
      @host = host
      @feature_flags = Concurrent::Array.new
      @group_type_mapping = Concurrent::Hash.new
      @loaded_flags_successfully_once = Concurrent::AtomicBoolean.new
      @feature_flags_by_key = nil
      @feature_flag_request_timeout_seconds = feature_flag_request_timeout_seconds
      @on_error = on_error || proc { |status, error| }
      @quota_limited = Concurrent::AtomicBoolean.new(false)
      @task =
        Concurrent::TimerTask.new(
          execution_interval: polling_interval
        ) { _load_feature_flags }

      # If no personal API key, disable local evaluation & thus polling for definitions
      if @personal_api_key.nil?
        logger.info 'No personal API key provided, disabling local evaluation'
        @loaded_flags_successfully_once.make_true
      else
        # load once before timer
        load_feature_flags
        @task.execute
      end
    end

    def load_feature_flags(force_reload = false)
      return unless @loaded_flags_successfully_once.false? || force_reload

      _load_feature_flags
    end

    def get_feature_variants(
      distinct_id,
      groups = {},
      person_properties = {},
      group_properties = {},
      raise_on_error = false
    )
      # TODO: Convert to options hash for easier argument passing
      flags_data = get_all_flags_and_payloads(
        distinct_id,
        groups,
        person_properties,
        group_properties,
        false,
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

    def get_flags(distinct_id, groups = {}, person_properties = {}, group_properties = {})
      request_data = {
        distinct_id: distinct_id,
        groups: groups,
        person_properties: person_properties,
        group_properties: group_properties
      }

      flags_response = _request_feature_flag_evaluation(request_data)

      # Only normalize if we have flags in the response
      if flags_response[:flags]
        # v4 format
        flags_hash = flags_response[:flags].transform_values do |flag|
          FeatureFlag.new(flag)
        end
        flags_response[:flags] = flags_hash
        flags_response[:featureFlags] = flags_hash.transform_values(&:get_value).transform_keys(&:to_sym)
        flags_response[:featureFlagPayloads] = flags_hash.transform_values(&:payload).transform_keys(&:to_sym)
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
      _request_remote_config_payload(flag_key)
    end

    def get_feature_flag(
      key,
      distinct_id,
      groups = {},
      person_properties = {},
      group_properties = {},
      only_evaluate_locally = false
    )
      # make sure they're loaded on first run
      load_feature_flags

      symbolize_keys! groups
      symbolize_keys! person_properties
      symbolize_keys! group_properties

      group_properties.each_value do |value|
        symbolize_keys!(value)
      end

      response = nil
      feature_flag = nil

      @feature_flags.each do |flag|
        if key == flag[:key]
          feature_flag = flag
          break
        end
      end

      unless feature_flag.nil?
        begin
          response = _compute_flag_locally(feature_flag, distinct_id, groups, person_properties, group_properties)
          logger.debug "Successfully computed flag locally: #{key} -> #{response}"
        rescue InconclusiveMatchError => e
          logger.debug "Failed to compute flag #{key} locally: #{e}"
        rescue StandardError => e
          @on_error.call(-1, "Error computing flag locally: #{e}. #{e.backtrace.join("\n")}")
        end
      end

      flag_was_locally_evaluated = !response.nil?

      request_id = nil

      if !flag_was_locally_evaluated && !only_evaluate_locally
        begin
          flags_data = get_all_flags_and_payloads(distinct_id, groups, person_properties, group_properties, false, true)
          if flags_data.key?(:featureFlags)
            flags = stringify_keys(flags_data[:featureFlags] || {})
            request_id = flags_data[:requestId]
          else
            logger.debug "Missing feature flags key: #{flags_data.to_json}"
            flags = {}
          end

          response = flags[key]
          response = false if response.nil?
          logger.debug "Successfully computed flag remotely: #{key} -> #{response}"
        rescue StandardError => e
          @on_error.call(-1, "Error computing flag remotely: #{e}. #{e.backtrace.join("\n")}")
        end
      end

      [response, flag_was_locally_evaluated, request_id]
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

      flags = {}
      payloads = {}
      fallback_to_server = @feature_flags.empty?
      request_id = nil # Only for /flags requests

      @feature_flags.each do |flag|
        match_value = _compute_flag_locally(flag, distinct_id, groups, person_properties, group_properties)
        flags[flag[:key]] = match_value
        match_payload = _compute_flag_payload_locally(flag[:key], match_value)
        payloads[flag[:key]] = match_payload if match_payload
      rescue InconclusiveMatchError
        fallback_to_server = true
      rescue StandardError => e
        @on_error.call(-1, "Error computing flag locally: #{e}. #{e.backtrace.join("\n")} ")
        fallback_to_server = true
      end

      if fallback_to_server && !only_evaluate_locally
        begin
          flags_and_payloads = get_flags(distinct_id, groups, person_properties, group_properties)

          unless flags_and_payloads.key?(:featureFlags)
            raise StandardError, "Error flags response: #{flags_and_payloads}"
          end

          # Check if feature_flags are quota limited
          if flags_and_payloads[:quotaLimited]&.include?('feature_flags')
            logger.warn '[FEATURE FLAGS] Quota limited for feature flags'
            flags = {}
            payloads = {}
          else
            flags = stringify_keys(flags_and_payloads[:featureFlags] || {})
            payloads = stringify_keys(flags_and_payloads[:featureFlagPayloads] || {})
            request_id = flags_and_payloads[:requestId]
          end
        rescue StandardError => e
          @on_error.call(-1, "Error computing flag remotely: #{e}")
          raise if raise_on_error
        end
      end

      {
        featureFlags: flags,
        featureFlagPayloads: payloads,
        requestId: request_id
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
      if match_value.nil?
        match_value = get_feature_flag(
          key,
          distinct_id,
          groups,
          person_properties,
          group_properties,
          true
        )[0]
      end
      response = nil
      response = _compute_flag_payload_locally(key, match_value) unless match_value.nil?
      if response.nil? && !only_evaluate_locally
        flags_payloads = get_feature_payloads(distinct_id, groups, person_properties, group_properties)
        response = flags_payloads[key.downcase] || nil
      end
      response
    end

    def shutdown_poller
      @task.shutdown
    end

    # Class methods

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

    def self.match_property(property, property_values)
      # only looks for matches where key exists in property_values
      # doesn't support operator is_not_set

      PostHog::Utils.symbolize_keys! property
      PostHog::Utils.symbolize_keys! property_values

      key = property[:key].to_sym
      value = property[:value]
      operator = property[:operator] || 'exact'

      if !property_values.key?(key)
        raise InconclusiveMatchError, "Property #{key} not found in property_values"
      elsif operator == 'is_not_set'
        raise InconclusiveMatchError, 'Operator is_not_set not supported'
      end

      override_value = property_values[key]

      case operator
      when 'exact', 'is_not'
        if value.is_a?(Array)
          values_stringified = value.map { |val| val.to_s.downcase }
          return values_stringified.any?(override_value.to_s.downcase) if operator == 'exact'

          return values_stringified.none?(override_value.to_s.downcase)

        end
        if operator == 'exact'
          value.to_s.downcase == override_value.to_s.downcase
        else
          value.to_s.downcase != override_value.to_s.downcase
        end
      when 'is_set'
        property_values.key?(key)
      when 'icontains'
        override_value.to_s.downcase.include?(value.to_s.downcase)
      when 'not_icontains'
        !override_value.to_s.downcase.include?(value.to_s.downcase)
      when 'regex'
        PostHog::Utils.is_valid_regex(value.to_s) && !Regexp.new(value.to_s).match(override_value.to_s).nil?
      when 'not_regex'
        PostHog::Utils.is_valid_regex(value.to_s) && Regexp.new(value.to_s).match(override_value.to_s).nil?
      when 'gt', 'gte', 'lt', 'lte'
        parsed_value = nil
        begin
          parsed_value = Float(value)
        rescue StandardError # rubocop:disable Lint/SuppressedException
        end
        if !parsed_value.nil? && !override_value.nil?
          if override_value.is_a?(String)
            compare(override_value, value.to_s, operator)
          else
            compare(override_value, parsed_value, operator)
          end
        else
          compare(override_value.to_s, value.to_s, operator)
        end
      when 'is_date_before', 'is_date_after'
        override_date = PostHog::Utils.convert_to_datetime(override_value.to_s)
        parsed_date = relative_date_parse_for_feature_flag_matching(value.to_s)

        parsed_date = PostHog::Utils.convert_to_datetime(value.to_s) if parsed_date.nil?

        raise InconclusiveMatchError, 'Invalid date format' unless parsed_date

        if operator == 'is_date_before'
          override_date < parsed_date
        elsif operator == 'is_date_after'
          override_date > parsed_date
        end
      else
        raise InconclusiveMatchError, "Unknown operator: #{operator}"
      end
    end

    private

    def _compute_flag_locally(flag, distinct_id, groups = {}, person_properties = {}, group_properties = {})
      raise InconclusiveMatchError, 'Flag has experience continuity enabled' if flag[:ensure_experience_continuity]

      return false unless flag[:active]

      flag_filters = flag[:filters] || {}

      aggregation_group_type_index = flag_filters[:aggregation_group_type_index]
      return match_feature_flag_properties(flag, distinct_id, person_properties) if aggregation_group_type_index.nil?

      group_name = @group_type_mapping[aggregation_group_type_index.to_s.to_sym]

      if group_name.nil?
        logger.warn(
          "[FEATURE FLAGS] Unknown group type index #{aggregation_group_type_index} for feature flag #{flag[:key]}"
        )
        # failover to `/flags/`
        raise InconclusiveMatchError, 'Flag has unknown group type index'
      end

      group_name_symbol = group_name.to_sym

      unless groups.key?(group_name_symbol)
        # Group flags are never enabled if appropriate `groups` aren't passed in
        # don't failover to `/flags/`, since response will be the same
        logger.warn "[FEATURE FLAGS] Can't compute group feature flag: #{flag[:key]} without group names passed in"
        return false
      end

      focused_group_properties = group_properties[group_name_symbol]
      match_feature_flag_properties(flag, groups[group_name_symbol], focused_group_properties)
    end

    def _compute_flag_payload_locally(key, match_value)
      return nil if @feature_flags_by_key.nil?

      response = nil
      if [true, false].include? match_value
        response = @feature_flags_by_key.dig(key, :filters, :payloads, match_value.to_s.to_sym)
      elsif match_value.is_a? String
        response = @feature_flags_by_key.dig(key, :filters, :payloads, match_value.to_sym)
      end
      response
    end

    def match_feature_flag_properties(flag, distinct_id, properties)
      flag_filters = flag[:filters] || {}

      flag_conditions = flag_filters[:groups] || []
      is_inconclusive = false
      result = nil

      # Stable sort conditions with variant overrides to the top. This ensures that if overrides are present, they are
      # evaluated first, and the variant override is applied to the first matching condition.
      sorted_flag_conditions = flag_conditions.each_with_index.sort_by do |condition, idx|
        [condition[:variant].nil? ? 1 : -1, idx]
      end

      # NOTE: This NEEDS to be `each` because `each_key` breaks
      # This is not a hash, it's just an array with 2 entries
      sorted_flag_conditions.each do |condition, _idx| # rubocop:disable Style/HashEachMethods
        if is_condition_match(flag, distinct_id, condition, properties)
          variant_override = condition[:variant]
          flag_multivariate = flag_filters[:multivariate] || {}
          flag_variants = flag_multivariate[:variants] || []
          variant = if flag_variants.map { |variant| variant[:key] }.include?(condition[:variant])
                      variant_override
                    else
                      get_matching_variant(flag, distinct_id)
                    end
          result = variant || true
          break
        end
      rescue InconclusiveMatchError
        is_inconclusive = true
      end

      if !result.nil?
        return result
      elsif is_inconclusive
        raise InconclusiveMatchError, "Can't determine if feature flag is enabled or not with given properties"
      end

      # We can only return False when all conditions are False
      false
    end

    # TODO: Rename to `condition_match?` in future version
    def is_condition_match(flag, distinct_id, condition, properties) # rubocop:disable Naming/PredicateName
      rollout_percentage = condition[:rollout_percentage]

      unless (condition[:properties] || []).empty?
        if !condition[:properties].all? do |prop|
          # Skip flag dependencies as they are not supported in local evaluation
          if prop[:type] == 'flag'
            logger.warn(
              '[FEATURE FLAGS] Flag dependency filters are not supported in local evaluation. ' \
              "Skipping condition for flag '#{flag[:key]}' with dependency on flag '#{prop[:key]}'"
            )
            next true
          end
          FeatureFlagsPoller.match_property(prop, properties)
        end
          return false
        elsif rollout_percentage.nil?
          return true
        end
      end

      return false if !rollout_percentage.nil? && (_hash(flag[:key], distinct_id) > (rollout_percentage.to_f / 100))

      true
    end

    # This function takes a distinct_id and a feature flag key and returns a float between 0 and 1.
    # Given the same distinct_id and key, it'll always return the same float. These floats are
    # uniformly distributed between 0 and 1, so if we want to show this feature to 20% of traffic
    # we can do _hash(key, distinct_id) < 0.2
    def _hash(key, distinct_id, salt = '')
      hash_key = Digest::SHA1.hexdigest "#{key}.#{distinct_id}#{salt}"
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
      begin
        res = _request_feature_flag_definitions
      rescue StandardError => e
        @on_error.call(-1, e.to_s)
        return
      end

      # Handle quota limits with 402 status
      if res.is_a?(Hash) && res[:status] == 402
        logger.warn(
          '[FEATURE FLAGS] Feature flags quota limit exceeded - unsetting all local flags. ' \
          'Learn more about billing limits at https://posthog.com/docs/billing/limits-alerts'
        )
        @feature_flags = Concurrent::Array.new
        @feature_flags_by_key = {}
        @group_type_mapping = Concurrent::Hash.new
        @loaded_flags_successfully_once.make_false
        @quota_limited.make_true
        return
      end

      if res.key?(:flags)
        @feature_flags = res[:flags] || []
        @feature_flags_by_key = {}
        @feature_flags.each do |flag|
          @feature_flags_by_key[flag[:key]] = flag unless flag[:key].nil?
        end
        @group_type_mapping = res[:group_type_mapping] || {}

        logger.debug "Loaded #{@feature_flags.length} feature flags"
        @loaded_flags_successfully_once.make_true if @loaded_flags_successfully_once.false?
      else
        logger.debug "Failed to load feature flags: #{res}"
      end
    end

    def _request_feature_flag_definitions
      uri = URI("#{@host}/api/feature_flag/local_evaluation?token=#{@project_api_key}")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{@personal_api_key}"

      _request(uri, req)
    end

    def _request_feature_flag_evaluation(data = {})
      uri = URI("#{@host}/flags/?v=2")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      data['token'] = @project_api_key
      req.body = data.to_json

      _request(uri, req, @feature_flag_request_timeout_seconds)
    end

    def _request_remote_config_payload(flag_key)
      uri = URI("#{@host}/api/projects/@current/feature_flags/#{flag_key}/remote_config/")
      req = Net::HTTP::Get.new(uri)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = "Bearer #{@personal_api_key}"

      _request(uri, req, @feature_flag_request_timeout_seconds)
    end

    # rubocop:disable Lint/ShadowedException
    def _request(uri, request_object, timeout = nil)
      request_object['User-Agent'] = "posthog-ruby#{PostHog::VERSION}"
      request_timeout = timeout || 10

      begin
        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == 'https',
          read_timeout: request_timeout
        ) do |http|
          res = http.request(request_object)

          # Parse response body to hash
          begin
            response = JSON.parse(res.body, { symbolize_names: true })
            # Only add status if response is a hash
            response = response.merge({ status: res.code.to_i }) if response.is_a?(Hash)
            return response
          rescue JSON::ParserError
            # Handle case when response isn't valid JSON
            return { error: 'Invalid JSON response', body: res.body, status: res.code.to_i }
          end
        end
      rescue Timeout::Error,
             Errno::EINVAL,
             Errno::ECONNRESET,
             EOFError,
             Net::HTTPBadResponse,
             Net::HTTPHeaderSyntaxError,
             Net::ReadTimeout,
             Net::WriteTimeout,
             Net::ProtocolError
        logger.debug("Unable to complete request to #{uri}")
        raise
      end
    end
    # rubocop:enable Lint/ShadowedException
  end
end
