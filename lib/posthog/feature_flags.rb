require 'concurrent'
require 'net/http'
require 'json'
require 'posthog/version'
require 'posthog/logging'
require 'digest'

class PostHog

  class InconclusiveMatchError < StandardError
  end

  class FeatureFlagsPoller
    include PostHog::Logging

    def initialize(polling_interval, personal_api_key, project_api_key, host)
      @polling_interval = polling_interval || 60 * 5
      @personal_api_key = personal_api_key
      @project_api_key = project_api_key
      @host = host
      @feature_flags = Concurrent::Array.new
      @group_type_mapping = Concurrent::Hash.new
      @loaded_flags_successfully_once = Concurrent::AtomicBoolean.new

      @task =
        Concurrent::TimerTask.new(
          execution_interval: polling_interval,
        ) { _load_feature_flags }

      # If no personal API key, disable local evaluation & thus polling for definitions
      if !@personal_api_key.nil?
        # load once before timer
        load_feature_flags
        @task.execute
      else
        logger.info "No personal API key provided, disabling local evaluation"
        @loaded_flags_successfully_once.make_true
      end
    end

    def load_feature_flags(force_reload = false)
      if @loaded_flags_successfully_once.false? || force_reload
        _load_feature_flags
      end
    end

    def get_feature_variants(distinct_id, groups={}, person_properties={}, group_properties={})
      # TODO: why isn't the default simply {} ?
      groups = {} unless groups.is_a?(Hash)

      request_data = {
        "distinct_id": distinct_id,
        "groups": groups,
        "person_properties": person_properties,
        "group_properties": group_properties,
      }

      decide_data = _request_feature_flag_evaluation(request_data)

      if !decide_data.key?('featureFlags')
        raise StandardError.new(decide_data.to_json)
      else
        feature_variants = decide_data["featureFlags"] || {}
        return feature_variants
      end
    end

    def get_feature_flag(key, distinct_id, default_result = false, groups = {}, person_properties = {}, group_properties = {})
      # make sure they're loaded on first run
      load_feature_flags

      response = nil
      feature_flag = nil

      @feature_flags.each do |flag|
        if key == flag['key']
          feature_flag = flag
          break
        end
      end

      if !feature_flag.nil?
        begin
          response = _compute_flag_locally(feature_flag, distinct_id, groups, person_properties, group_properties)
        rescue InconclusiveMatchError => e
        rescue StandardError => e
          logger.error "Error computing flag locally: #{e}. #{e.backtrace.join("\n")}"
        end
      end

      if response.nil?
        begin
          flags = get_feature_variants(distinct_id, groups, person_properties, group_properties)
          response = flags[key]
        rescue StandardError => e
          logger.error "Error computing flag remotely: #{e}"
          response = default_result
        end
      end

      return response
    end

    def shutdown_poller()
      @task.shutdown
    end

    # Class methods

    def self.match_property(property, property_values)
      # only looks for matches where key exists in property_values
      # doesn't support operator is_not_set

      key = property['key']
      value = property['value']
      operator = property['operator'] || 'exact'

      if !property_values.has_key?(key)
        raise InconclusiveMatchError.new("Property #{key} not found in property_values")
      elsif operator == 'is_not_set'
        raise InconclusiveMatchError.new("Operator is_not_set not supported")
      end

      override_value = property_values[key]

      if operator == 'exact'
        if value.is_a?(Array)
          return value.include?(override_value)
        end
        return value == override_value
      elsif operator == 'is_not'
        if value.is_a?(Array)
          return !value.include?(override_value)
        end
        return value != override_value
      elsif operator == 'is_set'
        return property_values.has_key?(key)
      elsif operator == 'icontains'
        return override_value.to_s.downcase.include?(value.to_s.downcase)
      elsif operator == 'not_icontains'
        return !override_value.to_s.downcase.include?(value.to_s.downcase)
      elsif operator == 'regex'
        is_valid_regex(value.to_s) and !Regexp.new(value.to_s).match(override_value.to_s).nil?
      elsif operator == 'not_regex'
        is_valid_regex(value.to_s) and Regexp.new(value.to_s).match(override_value.to_s).nil?
      elsif operator == 'gt'
        override_value.class == value.class and override_value > value
      elsif operator == 'gte'
        override_value.class == value.class and override_value >= value
      elsif operator == 'lt'
        override_value.class == value.class and override_value < value
      elsif operator == 'lte'
        override_value.class == value.class and override_value <= value
      else
        return false
      end

    end

    def self.is_valid_regex(regex)
      begin
        Regexp.new(regex)
        return true
      rescue RegexpError
        return false
      end
    end

    private

    def _compute_flag_locally(flag, distinct_id, groups = {}, person_properties = {}, group_properties = {})
      if flag['ensure_experience_continuity']
        raise InconclusiveMatchError.new("Flag has experience continuity enabled")
      end

      flag_filters = flag['filters'] || {}
      aggregation_group_type_index = flag_filters['aggregation_group_type_index']
      if !aggregation_group_type_index.nil?
        group_name = @group_type_mapping[aggregation_group_type_index.to_s]

        if group_name.nil?
          logger.warn "[FEATURE FLAGS] Unknown group type index #{aggregation_group_type_index} for feature flag #{flag['key']}"
          # failover to `/decide/`
          raise InconclusiveMatchError.new("Flag has unknown group type index")
        end

        if !groups.has_key?(group_name)
          # Group flags are never enabled if appropriate `groups` aren't passed in
          # don't failover to `/decide/`, since response will be the same
          logger.warn "[FEATURE FLAGS] Can't compute group feature flag: #{flag['key']} without group names passed in"
          return false
        end

        focused_group_properties = group_properties[group_name]
        return match_feature_flag_properties(flag, groups[group_name], focused_group_properties)
      else
        return match_feature_flag_properties(flag, distinct_id, person_properties)
      end

    end

    def match_feature_flag_properties(flag, distinct_id, properties)
      flag_filters = flag['filters'] || {}
      flag_conditions = flag_filters['groups'] || []
      is_inconclusive = false
      result = nil

      flag_conditions.each do |condition|
        begin
          if is_condition_match(flag, distinct_id, condition, properties)
            result = get_matching_variant(flag, distinct_id) || true
            break
          end
        rescue InconclusiveMatchError => e
          is_inconclusive = true
        end
      end

      if !result.nil?
        return result
      elsif is_inconclusive
        raise InconclusiveMatchError.new("Can't determine if feature flag is enabled or not with given properties")
      end

      # We can only return False when either all conditions are False, or
      # no condition was inconclusive.
      return false
    end

    def is_condition_match(flag, distinct_id, condition, properties)
      rollout_percentage = condition['rollout_percentage']

      if !(condition['properties'] || []).empty?
        if !condition['properties'].all? { |prop|
            FeatureFlagsPoller.match_property(prop, properties)
          }
          return false
        elsif rollout_percentage.nil?
          return true
        end
      end

      if !rollout_percentage.nil? and _hash(flag['key'], distinct_id) > (rollout_percentage.to_f/100)
        return false
      end
      
      return true
    end

    # This function takes a distinct_id and a feature flag key and returns a float between 0 and 1.
    # Given the same distinct_id and key, it'll always return the same float. These floats are
    # uniformly distributed between 0 and 1, so if we want to show this feature to 20% of traffic
    # we can do _hash(key, distinct_id) < 0.2
    def _hash(key, distinct_id, salt="")
      hash_key = Digest::SHA1.hexdigest "#{key}.#{distinct_id}#{salt}"
      return (Integer(hash_key[0..14], 16).to_f / 0xfffffffffffffff)
    end

    def get_matching_variant(flag, distinct_id)
      hash_value = _hash(flag['key'], distinct_id, salt="variant")
      variant_lookup_table(flag).each do |variant|
        if (
           hash_value >= variant[:value_min] and hash_value <= variant[:value_max]
        )
          return variant[:key]
        end
      end
      return nil
    end

    def variant_lookup_table(flag)
      lookup_table = []
      value_min = 0
      multivariates = ((flag['filters'] || {})['multivariate'] || {})['variants'] || []
      multivariates.each do |variant|
        value_max = value_min + variant['rollout_percentage'].to_f / 100
        lookup_table << {'value_min': value_min, 'value_max': value_max, 'key': variant['key']}
        value_min = value_max
      end
      return lookup_table
    end

    def _load_feature_flags()
      res = _request_feature_flag_definitions
      @feature_flags.clear

      if !res.key?('flags')
        logger.error "Failed to load feature flags: #{res}"
      else
        @feature_flags = res['flags'].filter { |flag| flag['active'] }
        @group_type_mapping = res['group_type_mapping'] || {}
        if @loaded_flags_successfully_once.false?
          @loaded_flags_successfully_once.make_true
        end
      end
    end

    def _request_feature_flag_definitions
      uri = URI("#{@host}/api/feature_flag/local_evaluation?token=#{@project_api_key}")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{@personal_api_key}"
      req['User-Agent'] = "posthog-ruby#{PostHog::VERSION}"

      return _request(uri, req)
    end

    def _request_feature_flag_evaluation(data={})
      uri = URI("#{@host}/decide/?v=2")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      data['token'] = @project_api_key
      req.body = data.to_json

      return _request(uri, req)
    end

    def _request(uri, request_object)

      request_object['User-Agent'] = "posthog-ruby#{PostHog::VERSION}"

      begin
        res_body = nil
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
          res = http.request(request_object)
          p res
          res_body = JSON.parse(res.body)
          p res_body
          return res_body
        end
      rescue Timeout::Error,
             Errno::EINVAL,
             Errno::ECONNRESET,
             EOFError,
             Net::HTTPBadResponse,
             Net::HTTPHeaderSyntaxError,
             Net::ProtocolError => e
        logger.debug("Unable to complete request to #{uri}")
        throw e
      end
    end  
  end
end
