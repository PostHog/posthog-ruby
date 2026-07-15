# frozen_string_literal: true

module PostHog
  # Represents a feature flag returned by /flags v2.
  #
  # @api private
  class FeatureFlag
    attr_reader :key, :enabled, :variant, :reason, :metadata, :failed

    # @param json [Hash] Raw feature flag data returned by /flags.
    def initialize(json)
      json.transform_keys!(&:to_s)
      @key = json['key']
      @enabled = json['enabled']
      @variant = json['variant']
      @reason = json['reason'] ? EvaluationReason.new(json['reason']) : nil
      @metadata = json['metadata'] ? FeatureFlagMetadata.new(json['metadata'].transform_keys(&:to_s)) : nil
      @failed = json['failed']
    end

    # @return [String, Boolean] The variant value when present, otherwise the enabled status.
    # TODO: Rename to `value` in future version
    def get_value # rubocop:disable Naming/AccessorMethodName
      @variant || @enabled
    end

    # @return [Object, nil] The flag payload from metadata.
    def payload
      @metadata&.payload
    end

    # @param key [String, Symbol] The feature flag key.
    # @param value [String, Boolean] The feature flag value.
    # @param payload [Object, nil] The feature flag payload.
    # @return [PostHog::FeatureFlag]
    def self.from_value_and_payload(key, value, payload)
      new({
            'key' => key,
            'enabled' => value.is_a?(String) || value,
            'variant' => value.is_a?(String) ? value : nil,
            'reason' => nil,
            'metadata' => {
              'id' => nil,
              'version' => nil,
              'payload' => payload,
              'description' => nil
            }
          })
    end
  end

  # Represents the reason why a flag was enabled/disabled.
  #
  # @api private
  class EvaluationReason
    attr_reader :code, :description, :condition_index

    # @param json [Hash] Raw reason data returned by /flags.
    def initialize(json)
      json.transform_keys!(&:to_s)
      @code = json['code']
      @description = json['description']
      @condition_index = json['condition_index'].to_i if json['condition_index']
    end
  end

  # Represents metadata about a feature flag.
  #
  # @api private
  class FeatureFlagMetadata
    attr_reader :id, :version, :payload, :description, :has_experiment

    # @param json [Hash] Raw metadata returned by /flags.
    def initialize(json)
      json.transform_keys!(&:to_s)
      @id = json['id']
      @version = json['version']
      @payload = json['payload']
      @description = json['description']
      # Whether the flag is linked to an experiment. nil when the server
      # (an older deployment) does not report the field.
      @has_experiment = json['has_experiment']
    end
  end
end
