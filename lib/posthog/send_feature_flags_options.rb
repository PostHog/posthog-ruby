# frozen_string_literal: true

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
        only_evaluate_locally: hash[:only_evaluate_locally] || hash['only_evaluate_locally'],
        person_properties: hash[:person_properties] || hash['person_properties'],
        group_properties: hash[:group_properties] || hash['group_properties']
      )
    end
  end
end
