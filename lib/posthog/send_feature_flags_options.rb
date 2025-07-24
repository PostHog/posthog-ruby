# frozen_string_literal: true

require 'posthog/utils'

module PostHog
  # Options for configuring feature flag behavior in capture calls
  class SendFeatureFlagsOptions
    attr_reader :only_evaluate_locally, :person_properties, :group_properties

    def initialize(only_evaluate_locally: nil, person_properties: nil, group_properties: nil)
      @only_evaluate_locally = only_evaluate_locally
      @person_properties = person_properties || {}
      @group_properties = group_properties || {}
    end

    def to_h
      {
        only_evaluate_locally: @only_evaluate_locally,
        person_properties: @person_properties,
        group_properties: @group_properties
      }
    end

    def self.from_hash(hash)
      return nil unless hash.is_a?(Hash)

      new(
        only_evaluate_locally: PostHog::Utils.get_by_symbol_or_string_key(hash, :only_evaluate_locally),
        person_properties: PostHog::Utils.get_by_symbol_or_string_key(hash, :person_properties),
        group_properties: PostHog::Utils.get_by_symbol_or_string_key(hash, :group_properties)
      )
    end
  end
end
