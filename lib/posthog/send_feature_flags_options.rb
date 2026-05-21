# frozen_string_literal: true

require 'posthog/utils'

module PostHog
  # Options for configuring deprecated feature flag behavior in capture calls.
  #
  # @deprecated Prefer passing a {PostHog::FeatureFlagEvaluations} snapshot to `capture(flags:)`.
  class SendFeatureFlagsOptions
    # @return [Boolean, nil] Whether remote feature flag evaluation should be skipped.
    attr_reader :only_evaluate_locally

    # @return [Hash] Person properties to use for feature flag evaluation.
    attr_reader :person_properties

    # @return [Hash] Group properties to use for feature flag evaluation.
    attr_reader :group_properties

    # @param only_evaluate_locally [Boolean, nil] Skip remote feature flag evaluation.
    # @param person_properties [Hash, nil] Person properties to use for feature flag evaluation.
    # @param group_properties [Hash, nil] Group properties to use for feature flag evaluation.
    def initialize(only_evaluate_locally: nil, person_properties: nil, group_properties: nil)
      @only_evaluate_locally = only_evaluate_locally
      @person_properties = person_properties || {}
      @group_properties = group_properties || {}
    end

    # @return [Hash] A hash representation suitable for `capture(send_feature_flags:)`.
    def to_h
      {
        only_evaluate_locally: @only_evaluate_locally,
        person_properties: @person_properties,
        group_properties: @group_properties
      }
    end

    # @param hash [Hash]
    # @return [PostHog::SendFeatureFlagsOptions, nil]
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
