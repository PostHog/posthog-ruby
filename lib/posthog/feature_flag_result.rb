# frozen_string_literal: true

require 'json'

module PostHog
  # Represents the result of a feature flag evaluation
  # containing both the flag value and payload
  class FeatureFlagResult
    attr_reader :key, :variant, :payload

    def initialize(key:, enabled:, variant: nil, payload: nil)
      @key = key
      @enabled = enabled
      @variant = variant
      @payload = payload
    end

    # Returns the effective value of the feature flag
    # variant if present, otherwise enabled status
    def value
      @variant || @enabled
    end

    # Returns whether or not the feature flag evaluated as enabled
    def enabled?
      @enabled
    end

    # Factory method to create from flag value and payload
    def self.from_value_and_payload(key, value, payload)
      return nil if value.nil?

      parsed_payload = parse_payload(payload)

      if value.is_a?(String)
        new(key: key, enabled: true, variant: value, payload: parsed_payload)
      else
        new(key: key, enabled: value, payload: parsed_payload)
      end
    end

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

    private_class_method :parse_payload
  end
end
