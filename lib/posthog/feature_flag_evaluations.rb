require 'set'

class PostHog
  # A snapshot of feature flag evaluations for one distinct_id, returned by
  # PostHog::Client#evaluate_flags. Calls to #is_enabled / #get_flag fire the
  # `$feature_flag_called` event (deduped through the existing per-distinct_id
  # cache); #get_flag_payload does not. Pass the snapshot to `capture(flags:)`
  # to attach `$feature/<key>` and `$active_feature_flags` without a second
  # /flags request.
  class FeatureFlagEvaluations
    EVALUATED_LOCALLY_REASON = 'Evaluated locally'.freeze

    EvaluatedFlagRecord = Struct.new(
      :key, :enabled, :variant, :payload, :id, :version, :reason, :locally_evaluated,
      keyword_init: true
    )

    Host = Struct.new(:capture_flag_called_event_if_needed, :log_warning, keyword_init: true)

    attr_reader :distinct_id, :groups, :request_id, :evaluated_at, :flag_definitions_loaded_at

    def initialize(
      host: nil,
      distinct_id: nil,
      flags: {},
      groups: nil,
      disable_geoip: nil,
      request_id: nil,
      evaluated_at: nil,
      flag_definitions_loaded_at: nil,
      accessed: nil
    )
      @host = host
      @distinct_id = distinct_id || ''
      @flags = flags || {}
      @groups = groups
      @disable_geoip = disable_geoip
      @request_id = request_id
      @evaluated_at = evaluated_at
      @flag_definitions_loaded_at = flag_definitions_loaded_at
      @accessed = Set.new(accessed || [])
    end

    def keys
      @flags.keys
    end

    def is_enabled(key) # rubocop:disable Naming/PredicateName
      key = key.to_s
      flag = @flags[key]
      response = flag && flag.enabled ? true : false
      _record_access(key, flag, response)
      response
    end

    def get_flag(key)
      key = key.to_s
      flag = @flags[key]
      response =
        if flag.nil?
          nil
        elsif flag.variant
          flag.variant
        else
          (flag.enabled ? true : false)
        end
      _record_access(key, flag, response)
      response
    end

    def get_flag_payload(key)
      flag = @flags[key.to_s]
      flag ? flag.payload : nil
    end

    def only_accessed
      if @accessed.empty?
        @host.log_warning.call(
          'FeatureFlagEvaluations#only_accessed was called before any flags were accessed — ' \
          'attaching all evaluated flags as a fallback. ' \
          'See https://posthog.com/docs/feature-flags/server-sdks for details.'
        )
        return _clone_with(@flags)
      end
      filtered = @flags.select { |k, _| @accessed.include?(k) }
      _clone_with(filtered)
    end

    def only(keys)
      keys = Array(keys).map(&:to_s)
      missing = keys.reject { |k| @flags.key?(k) }
      unless missing.empty?
        @host.log_warning.call(
          'FeatureFlagEvaluations#only was called with flag keys that are not in the ' \
          "evaluation set and will be dropped: #{missing.join(', ')}"
        )
      end
      filtered = @flags.select { |k, _| keys.include?(k) }
      _clone_with(filtered)
    end

    # Builds the `$feature/<key>` and `$active_feature_flags` properties for a
    # captured event. Called from PostHog::Client#capture when `flags:` is set.
    def _get_event_properties
      properties = {}
      active = []
      @flags.each do |key, flag|
        properties["$feature/#{key}"] = flag.enabled ? (flag.variant || true) : false
        active << key if flag.enabled
      end
      properties['$active_feature_flags'] = active.sort unless active.empty?
      properties
    end

    private

    def _record_access(key, flag, response)
      @accessed.add(key)
      return if @distinct_id.nil? || @distinct_id.to_s.empty?

      properties = {
        '$feature_flag' => key,
        '$feature_flag_response' => response,
        'locally_evaluated' => flag && flag.locally_evaluated ? true : false,
        "$feature/#{key}" => response
      }

      if flag
        properties['$feature_flag_payload'] = flag.payload unless flag.payload.nil?
        properties['$feature_flag_id'] = flag.id if flag.id
        properties['$feature_flag_version'] = flag.version if flag.version
        properties['$feature_flag_reason'] = flag.reason if flag.reason
        if flag.locally_evaluated && @flag_definitions_loaded_at
          properties['$feature_flag_definitions_loaded_at'] = @flag_definitions_loaded_at
        end
      end

      properties['$feature_flag_request_id'] = @request_id if @request_id
      properties['$feature_flag_evaluated_at'] = @evaluated_at if @evaluated_at && !(flag && flag.locally_evaluated)
      properties['$feature_flag_error'] = 'flag_missing' if flag.nil?

      @host.capture_flag_called_event_if_needed.call(
        distinct_id: @distinct_id,
        key: key,
        response: response,
        properties: properties,
        groups: @groups,
        disable_geoip: @disable_geoip
      )
    end

    def _clone_with(flags)
      self.class.new(
        host: @host,
        distinct_id: @distinct_id,
        flags: flags,
        groups: @groups,
        disable_geoip: @disable_geoip,
        request_id: @request_id,
        evaluated_at: @evaluated_at,
        flag_definitions_loaded_at: @flag_definitions_loaded_at,
        accessed: @accessed.dup
      )
    end
  end
end
