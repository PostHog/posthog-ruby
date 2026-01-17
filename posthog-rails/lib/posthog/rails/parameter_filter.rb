# frozen_string_literal: true

module PostHog
  module Rails
    # Shared utility module for filtering sensitive parameters
    #
    # This module provides consistent parameter filtering across all PostHog Rails
    # components, leveraging Rails' built-in parameter filtering when available.
    # It automatically detects the correct Rails parameter filtering API based on
    # the Rails version.
    #
    # @example Usage in a class
    #   class MyClass
    #     include PostHog::Rails::ParameterFilter
    #
    #     def my_method(params)
    #       filtered = filter_sensitive_params(params)
    #       PostHog.capture(event: 'something', properties: filtered)
    #     end
    #   end
    module ParameterFilter
      EMPTY_HASH = {}.freeze
      MAX_STRING_LENGTH = 10_000
      MAX_DEPTH = 10

      if ::Rails.version.to_f >= 6.0
        def self.backend
          ActiveSupport::ParameterFilter
        end
      else
        def self.backend
          ActionDispatch::Http::ParameterFilter
        end
      end

      # Filter sensitive parameters from a hash, respecting Rails configuration.
      #
      # Uses Rails' configured filter_parameters (e.g., :password, :token, :api_key)
      # to automatically filter sensitive data that the Rails app has configured.
      #
      # @param params [Hash] The parameters to filter
      # @return [Hash] Filtered parameters with sensitive data masked
      def filter_sensitive_params(params)
        return EMPTY_HASH unless params.is_a?(Hash)

        filter_parameters = ::Rails.application.config.filter_parameters
        parameter_filter = ParameterFilter.backend.new(filter_parameters)

        parameter_filter.filter(params)
      end

      # Safely serialize a value to a JSON-compatible format.
      #
      # Handles circular references and complex objects by converting them to
      # simple primitives or string representations. This prevents SystemStackError
      # when serializing objects with circular references (like ActiveRecord models).
      #
      # @param value [Object] The value to serialize
      # @param seen [Set] Set of object_ids already visited (for cycle detection)
      # @param depth [Integer] Current recursion depth
      # @return [Object] A JSON-safe value (String, Numeric, Boolean, nil, Array, or Hash)
      def safe_serialize(value, seen = Set.new, depth = 0)
        return '[max depth exceeded]' if depth > MAX_DEPTH

        case value
        when nil, true, false, Integer, Float
          value
        when String
          truncate_string(value)
        when Symbol
          value.to_s
        when Time, DateTime
          value.iso8601(3)
        when Date
          value.iso8601
        when Array
          serialize_array(value, seen, depth)
        when Hash
          serialize_hash(value, seen, depth)
        else
          serialize_object(value, seen)
        end
      rescue StandardError => e
        "[serialization error: #{e.class}]"
      end

      private

      def truncate_string(str)
        return str if str.length <= MAX_STRING_LENGTH

        "#{str[0...MAX_STRING_LENGTH]}... (truncated)"
      end

      def serialize_array(array, seen, depth)
        return '[circular reference]' if seen.include?(array.object_id)

        seen = seen.dup.add(array.object_id)
        array.first(100).map { |item| safe_serialize(item, seen, depth + 1) }
      end

      def serialize_hash(hash, seen, depth)
        return '[circular reference]' if seen.include?(hash.object_id)

        seen = seen.dup.add(hash.object_id)
        result = {}
        hash.first(100).each do |key, val|
          result[key.to_s] = safe_serialize(val, seen, depth + 1)
        end
        result
      end

      def serialize_object(obj, seen)
        return '[circular reference]' if seen.include?(obj.object_id)

        # For ActiveRecord and similar objects, use id if available
        return "#{obj.class.name}##{obj.id}" if obj.respond_to?(:id) && obj.respond_to?(:class)

        # Try to_s as fallback, but limit length
        str = obj.to_s
        truncate_string(str)
      rescue StandardError
        "[#{obj.class.name}]"
      end
    end
  end
end
