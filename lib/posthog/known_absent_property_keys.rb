# frozen_string_literal: true

module PostHog
  # Person and group property keys the caller knows are absent for one flag evaluation.
  #
  # @api private
  class KnownAbsentPropertyKeys
    # The flags service rejects a longer list, counting duplicates, per group type for groups.
    MAX_KEYS = 1000
    PERSON_FIELD = 'person_property_keys_known_absent'
    GROUP_FIELD = 'group_property_keys_known_absent'
    # Persons-table fields such as `created_at` use this prefix and are never hidden by known absence.
    PERSON_METADATA_PREFIX = '__posthog_person_metadata__'
    # A listed key matches these operators and no others.
    MATCHING_OPERATORS = %w[is_not_set is_not not_icontains not_starts_with not_ends_with not_regex].freeze

    # @return [Set<String>] Listed person keys used for local matching.
    attr_reader :person_keys

    # Validates and normalizes the public inputs.
    #
    # @param person_property_keys_known_absent [Array<String, Symbol>, Set<String, Symbol>, nil]
    # @param group_property_keys_known_absent [Hash{String, Symbol => Array<String, Symbol>}, nil]
    # @return [PostHog::KnownAbsentPropertyKeys, nil] nil when neither input was provided.
    # @raise [ArgumentError] when an input has the wrong type or a list holds more than {MAX_KEYS} keys.
    def self.build(person_property_keys_known_absent, group_property_keys_known_absent)
      return nil if person_property_keys_known_absent.nil? && group_property_keys_known_absent.nil?

      person = if person_property_keys_known_absent.nil?
                 []
               else
                 validate_keys(person_property_keys_known_absent, PERSON_FIELD)
               end

      groups = {}
      unless group_property_keys_known_absent.nil?
        unless group_property_keys_known_absent.is_a?(Hash)
          raise ArgumentError, "#{GROUP_FIELD} must be a Hash of group type to property keys"
        end

        group_property_keys_known_absent.each do |group_type, keys|
          unless group_type.is_a?(String) || group_type.is_a?(Symbol)
            raise ArgumentError, "#{GROUP_FIELD} must use String or Symbol group types"
          end

          field = "#{GROUP_FIELD}[#{group_type}]"
          # A String and a Symbol can name the same group type, so their keys are merged before the limit check.
          merged = (groups[group_type.to_s] || []) + validate_keys(keys, field)
          raise ArgumentError, "#{field} allows at most #{MAX_KEYS} keys, got #{merged.size}" if merged.size > MAX_KEYS

          groups[group_type.to_s] = merged
        end
      end

      new(person, groups)
    end

    def self.validate_keys(keys, field)
      raise ArgumentError, "#{field} must be an Array of property keys" unless keys.is_a?(Array) || keys.is_a?(Set)
      raise ArgumentError, "#{field} allows at most #{MAX_KEYS} keys, got #{keys.size}" if keys.size > MAX_KEYS

      keys.map do |key|
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise ArgumentError, "#{field} must contain only String or Symbol keys"
        end

        key.to_s
      end
    end
    private_class_method :validate_keys

    def initialize(person, groups)
      @person = person
      @groups = groups
      @person_keys = person.reject { |key| key.start_with?(PERSON_METADATA_PREFIX) }.to_set.freeze
      @group_keys = groups.to_h { |group_type, keys| [group_type, keys.to_set.freeze] }.freeze
    end

    # @param group_type [String, Symbol]
    # @return [Set<String>, nil] Listed keys for that group type only.
    def group_keys(group_type)
      @group_keys[group_type.to_s]
    end

    # @return [Hash] The `/flags` request body fields, omitting a field with nothing listed.
    def request_fields
      fields = {}
      fields[PERSON_FIELD.to_sym] = @person unless @person.empty?
      groups = @groups.reject { |_group_type, keys| keys.empty? }
      fields[GROUP_FIELD.to_sym] = groups unless groups.empty?
      fields
    end
  end
end
