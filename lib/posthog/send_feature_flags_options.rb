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

    # @return [Array<String, Symbol>, Set<String, Symbol>, nil] Person property keys known to be absent.
    attr_reader :person_property_keys_known_absent

    # @return [Hash{String, Symbol => Array<String, Symbol>, Set<String, Symbol>}, nil] Group property keys known to
    #   be absent, by group type.
    attr_reader :group_property_keys_known_absent

    # @param only_evaluate_locally [Boolean, nil] Skip remote feature flag evaluation.
    # @param person_properties [Hash, nil] Person properties to use for feature flag evaluation.
    # @param group_properties [Hash, nil] Group properties to use for feature flag evaluation.
    # @param person_property_keys_known_absent [Array<String, Symbol>, Set<String, Symbol>, nil] Person property keys
    #   known to be absent.
    # @param group_property_keys_known_absent [Hash{String, Symbol => Array<String, Symbol>, Set<String, Symbol>}, nil]
    #   Group property keys known to be absent, by group type.
    def initialize(only_evaluate_locally: nil, person_properties: nil, group_properties: nil,
                   person_property_keys_known_absent: nil, group_property_keys_known_absent: nil)
      @only_evaluate_locally = only_evaluate_locally
      @person_properties = person_properties || {}
      @group_properties = group_properties || {}
      @person_property_keys_known_absent = person_property_keys_known_absent
      @group_property_keys_known_absent = group_property_keys_known_absent
    end

    # @return [Hash] A hash representation suitable for `capture(send_feature_flags:)`.
    def to_h
      hash = {
        only_evaluate_locally: @only_evaluate_locally,
        person_properties: @person_properties,
        group_properties: @group_properties
      }
      unless @person_property_keys_known_absent.nil?
        hash[:person_property_keys_known_absent] = @person_property_keys_known_absent
      end
      unless @group_property_keys_known_absent.nil?
        hash[:group_property_keys_known_absent] = @group_property_keys_known_absent
      end
      hash
    end

    # @param hash [Hash]
    # @return [PostHog::SendFeatureFlagsOptions, nil]
    def self.from_hash(hash)
      return nil unless hash.is_a?(Hash)

      new(
        only_evaluate_locally: PostHog::Utils.get_by_symbol_or_string_key(hash, :only_evaluate_locally),
        person_properties: PostHog::Utils.get_by_symbol_or_string_key(hash, :person_properties),
        group_properties: PostHog::Utils.get_by_symbol_or_string_key(hash, :group_properties),
        person_property_keys_known_absent:
          PostHog::Utils.get_by_symbol_or_string_key(hash, :person_property_keys_known_absent),
        group_property_keys_known_absent:
          PostHog::Utils.get_by_symbol_or_string_key(hash, :group_property_keys_known_absent)
      )
    end
  end
end
