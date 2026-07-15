# frozen_string_literal: true

require 'set'

module PostHog
  # A snapshot of feature flag evaluations for one distinct_id, returned by
  # PostHog::Client#evaluate_flags. Calls to {#enabled?} / {#get_flag} fire the
  # `$feature_flag_called` event (deduped through the existing per-distinct_id
  # cache); {#get_flag_payload} does not. Pass the snapshot to `capture(flags:)`
  # to attach `$feature/<key>` and `$active_feature_flags` without a second
  # /flags request.
  class FeatureFlagEvaluations
    EVALUATED_LOCALLY_REASON = 'Evaluated locally'

    EvaluatedFlagRecord = Struct.new(
      :key, :enabled, :variant, :payload, :id, :version, :reason, :locally_evaluated, :has_experiment,
      keyword_init: true
    )

    Host = Struct.new(:capture_flag_called_event_if_needed, :log_warning, keyword_init: true)

    # @return [String] The distinct id these evaluations belong to.
    attr_reader :distinct_id

    # @return [Hash, nil] Group analytics mapping used for evaluation.
    attr_reader :groups

    # @return [String, nil] Request id returned by the /flags endpoint.
    attr_reader :request_id

    # @return [String, nil] Evaluation timestamp returned by the /flags endpoint.
    attr_reader :evaluated_at

    # @return [Time, nil] When local flag definitions were loaded.
    attr_reader :flag_definitions_loaded_at

    # @param host [Host, nil] Internal host callbacks used to record flag access events.
    # @param distinct_id [String, nil] The distinct id these evaluations belong to.
    # @param flags [Hash] Evaluated flags keyed by flag key.
    # @param groups [Hash, nil] Group analytics mapping from group type to group key.
    # @param disable_geoip [Boolean, nil] Whether GeoIP was disabled during evaluation.
    # @param request_id [String, nil] The request id returned by the /flags endpoint.
    # @param evaluated_at [String, nil] The evaluation timestamp returned by the /flags endpoint.
    # @param flag_definitions_loaded_at [Time, nil] When local flag definitions were loaded.
    # @param errors_while_computing [Boolean] Whether the server reported errors while computing flags.
    # @param quota_limited [Boolean] Whether feature flag evaluation was quota limited.
    # @param accessed [Array<String>, Set<String>, nil] Flag keys already accessed by this snapshot.
    def initialize(
      host: nil,
      distinct_id: nil,
      flags: {},
      groups: nil,
      disable_geoip: nil,
      request_id: nil,
      evaluated_at: nil,
      flag_definitions_loaded_at: nil,
      errors_while_computing: false,
      quota_limited: false,
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
      @errors_while_computing = errors_while_computing
      @quota_limited = quota_limited
      @accessed = Set.new(accessed || [])
    end

    # @return [Array<String>] The evaluated flag keys in this snapshot.
    def keys
      @flags.keys
    end

    # @param key [String, Symbol] The feature flag key.
    # @return [Boolean] true when the flag is enabled, false when disabled or missing.
    def enabled?(key)
      key = key.to_s
      flag = @flags[key]
      _record_access(key, flag)
      flag&.enabled ? true : false
    end

    # @param key [String, Symbol] The feature flag key.
    # @return [String, Boolean, nil] Variant string for multivariate flags, true/false for boolean flags,
    #   or nil when the flag was not returned by the evaluation.
    def get_flag(key)
      key = key.to_s
      flag = @flags[key]
      _record_access(key, flag)
      _flag_value(flag)
    end

    # @param key [String, Symbol] The feature flag key.
    # @return [Object, nil] The parsed payload for the flag, if any.
    def get_flag_payload(key)
      flag = @flags[key.to_s]
      flag&.payload
    end

    # Order-dependent: if nothing has been accessed yet, the returned snapshot is
    # empty. The method honors its name — pre-access flags before calling this if
    # you want a populated result.
    # @return [PostHog::FeatureFlagEvaluations] A snapshot containing only flags already accessed with
    #   {#enabled?} or {#get_flag}.
    def only_accessed
      _clone_with(@flags.slice(*@accessed))
    end

    # @param keys [Array<String, Symbol>, String, Symbol] Flag keys to keep in the returned snapshot.
    # @return [PostHog::FeatureFlagEvaluations] A snapshot containing only the requested keys that exist.
    def only(keys)
      keys = Array(keys).map(&:to_s)
      missing = keys.reject { |k| @flags.key?(k) }
      unless missing.empty?
        @host.log_warning.call(
          'FeatureFlagEvaluations#only was called with flag keys that are not in the ' \
          "evaluation set and will be dropped: #{missing.join(', ')}"
        )
      end
      filtered = @flags.slice(*keys)
      _clone_with(filtered)
    end

    # Builds the `$feature/<key>` and `$active_feature_flags` properties for a
    # captured event. Called from PostHog::Client#capture when `flags:` is set.
    #
    # @api private
    # @return [Hash]
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

    # Canonical "stored" value for a flag — used for both the
    # `$feature_flag_response` event property and the dedup cache key, so
    # `enabled?` and `get_flag` collapse to a single exposure per flag.
    # Variant string when present, else boolean enabled status; `nil` for
    # unknown flags.
    def _flag_value(flag)
      return nil if flag.nil?
      return flag.variant if flag.variant

      flag.enabled ? true : false
    end

    def _record_access(key, flag)
      @accessed.add(key)
      return if @distinct_id.nil? || @distinct_id.to_s.empty?

      response = _flag_value(flag)
      properties = {
        '$feature_flag' => key,
        '$feature_flag_response' => response,
        'locally_evaluated' => flag&.locally_evaluated ? true : false,
        "$feature/#{key}" => response
      }

      if flag
        properties['$feature_flag_has_experiment'] = flag.has_experiment unless flag.has_experiment.nil?
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

      errors = []
      errors << 'errors_while_computing_flags' if @errors_while_computing
      errors << 'quota_limited' if @quota_limited
      errors << 'flag_missing' if flag.nil?
      properties['$feature_flag_error'] = errors.join(',') unless errors.empty?

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
        errors_while_computing: @errors_while_computing,
        quota_limited: @quota_limited,
        accessed: @accessed.dup
      )
    end
  end
end
