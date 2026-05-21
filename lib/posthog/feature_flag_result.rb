# frozen_string_literal: true

require 'json'

module PostHog
  # Represents the result of a feature flag evaluation
  # containing both the flag value and payload
  class FeatureFlagResult
    # @return [String, Symbol] The feature flag key.
    attr_reader :key

    # @return [String, nil] The variant key for multivariate flags.
    attr_reader :variant

    # @return [Object, nil] The parsed feature flag payload.
    attr_reader :payload

    # @param key [String, Symbol] The feature flag key.
    # @param enabled [Boolean] Whether the feature flag is enabled.
    # @param variant [String, nil] The variant key for multivariate flags.
    # @param payload [Object, nil] The parsed feature flag payload.
    def initialize(key:, enabled:, variant: nil, payload: nil)
      @key = key
      @enabled = enabled
      @variant = variant
      @payload = payload
    end

    # Returns the effective value of the feature flag: variant if present,
    # otherwise enabled status.
    #
    # @return [String, Boolean]
    def value
      @variant || @enabled
    end

    # Returns whether or not the feature flag evaluated as enabled.
    #
    # @return [Boolean]
    def enabled?
      @enabled
    end

    # Factory method to create from flag value and payload.
    #
    # @param key [String, Symbol] The feature flag key.
    # @param value [String, Boolean, nil] The raw feature flag value.
    # @param payload [Object, String, nil] The raw or JSON-encoded feature flag payload.
    # @return [PostHog::FeatureFlagResult, nil]
    def self.from_value_and_payload(key, value, payload)
      return nil if value.nil?

      parsed_payload = parse_payload(payload)

      if value.is_a?(String)
        new(key: key, enabled: true, variant: value, payload: parsed_payload)
      else
        new(key: key, enabled: value, payload: parsed_payload)
      end
    end

    # Deserialize a flag payload. Strings are JSON-parsed (with the raw string
    # returned when the body is not valid JSON); already-deserialized values
    # pass through. Public so {FeatureFlagEvaluations} can normalize payloads
    # the same way {FeatureFlagResult} does.
    #
    # @param payload [Object, String, nil] The raw payload value.
    # @return [Object, nil] The parsed payload.
    def self.parse_payload(payload)
      return nil if payload.nil?
      return payload unless payload.is_a?(String)
      return nil if payload.empty?

      begin
        JSON.parse(payload)
      rescue JSON::ParserError
        payload
      end
    end
  end
end
