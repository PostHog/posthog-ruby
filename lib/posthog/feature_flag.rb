class PostHog
  # Represents a feature flag returned by /flags v2
  class FeatureFlag
    attr_reader :key, :enabled, :variant, :reason, :metadata

    def initialize(json)
      json.transform_keys!(&:to_s)
      @key = json['key']
      @enabled = json['enabled']
      @variant = json['variant']
      @reason = json['reason'] ? PostHog::EvaluationReason.new(json['reason']) : nil
      @metadata = json['metadata'] ? PostHog::FeatureFlagMetadata.new(json['metadata'].transform_keys(&:to_s)) : nil
    end

    # TODO: Rename to `value` in future version
    def get_value # rubocop:disable Naming/AccessorMethodName
      @variant || @enabled
    end

    def payload
      @metadata.payload if @metadata
    end

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

  # Represents the reason why a flag was enabled/disabled
  class EvaluationReason
    attr_reader :code, :description, :condition_index

    def initialize(json)
      json.transform_keys!(&:to_s)
      @code = json['code']
      @description = json['description']
      @condition_index = json['condition_index'].to_i if json['condition_index']
    end
  end

  # Represents metadata about a feature flag
  class FeatureFlagMetadata
    attr_reader :id, :version, :payload, :description

    def initialize(json)
      json.transform_keys!(&:to_s)
      @id = json['id']
      @version = json['version']
      @payload = json['payload']
      @description = json['description']
    end
  end
end
