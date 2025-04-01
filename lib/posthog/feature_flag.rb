# Represents a feature flag returned by /decide v4
class FeatureFlag
  attr_reader :key, :enabled, :variant, :reason, :metadata

  def initialize(json)
    @key = json["key"]
    @enabled = json["enabled"]
    @variant = json["variant"]
    @reason = json["reason"] ? EvaluationReason.new(json["reason"]) : nil
    @metadata = json["metadata"] ? Metadata.new(json["metadata"].transform_keys(&:to_s)) : nil
  end

  def get_value
    @variant || @enabled
  end

  def payload
    @metadata&.payload
  end

  def self.from_value_and_payload(key, value, payload)
    new({
      "key" => key,
      "enabled" => value.is_a?(String) ? true : value,
      "variant" => value.is_a?(String) ? value : nil,
      "reason" => nil,
      "metadata" => {
        "id" => nil,
        "version" => nil,
        "payload" => payload,
        "description" => nil
      }
    })
  end
end

# Represents the reason why a flag was enabled/disabled
class EvaluationReason
  attr_reader :code, :description, :condition_index

  def initialize(json)
    @code = json["code"]
    @description = json["description"]
    @condition_index = json["condition_index"]
  end
end

# Represents metadata about a feature flag
class Metadata
  attr_reader :id, :version, :payload, :description

  def initialize(json)
    @id = json["id"]
    @version = json["version"]
    @payload = json["payload"]
    @description = json["description"]
  end
end