# frozen_string_literal: true

# Portions of this file are derived from getsentry/sentry-ruby
# Copyright (c) 2020 Sentry
# Licensed under the MIT License: https://github.com/getsentry/sentry-ruby/blob/master/LICENSE

module PostHog
  module Rails
    # Shared utility module for filtering sensitive parameters
    #
    # This module provides consistent parameter filtering across all PostHog Rails
    # components, leveraging Rails' built-in parameter filtering when available.
    # It automatically detects the correct Rails parameter filtering API based on
    # the Rails version.
    #
    # @api private
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
      MAX_SERIALIZED_BYTES = 32_768
      MAX_SERIALIZED_NODES = 1_000

      class UnsafeFilterMetadata < StandardError; end
      private_constant :UnsafeFilterMetadata

      if ::Rails.version.to_f >= 6.0
        # @return [Class] Rails parameter filter backend.
        def self.backend
          ActiveSupport::ParameterFilter
        end
      else
        # @return [Class] Rails parameter filter backend.
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
        return params unless ::Rails.application

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
      def safe_serialize(value, seen = Set.new, depth = 0, budget = nil)
        budget ||= { bytes: MAX_SERIALIZED_BYTES, nodes: MAX_SERIALIZED_NODES }
        return '[size limit exceeded]' if budget[:bytes] <= 0 || budget[:nodes] <= 0

        budget[:nodes] -= 1
        return '[max depth exceeded]' if depth > MAX_DEPTH

        case value
        when nil, true, false, Integer
          value
        when Float
          value.finite? ? value : value.to_s
        when String
          serialize_string(value, budget)
        when Symbol
          serialize_string(value.to_s, budget)
        when Time, DateTime
          value.iso8601(3)
        when Date
          value.iso8601
        when Array
          serialize_array(value, seen, depth, budget)
        when Hash
          serialize_hash(value, seen, depth, budget)
        else
          serialize_string(serialize_object(value, seen), budget)
        end
      rescue StandardError => e
        "[serialization error: #{e.class}]"
      end

      private

      def filtered_metadata(value)
        budget = { bytes: MAX_SERIALIZED_BYTES, nodes: MAX_SERIALIZED_NODES }
        snapshot = snapshot_filter_metadata(value, Set.new, 0, budget, {}.compare_by_identity)
        safe_serialize(filter_sensitive_params(snapshot))
      rescue StandardError
        EMPTY_HASH
      end

      # Rails Procs must see original keys, scalar types and complete values/root data.
      # Reject unsafe snapshots as a whole rather than change a scrubber's conditions.
      def snapshot_filter_metadata(value, seen, depth, budget, copies)
        raise UnsafeFilterMetadata if depth > MAX_DEPTH || budget[:nodes] <= 0

        budget[:nodes] -= 1
        case value
        when Hash, Array
          raise UnsafeFilterMetadata if value.size > 100 || seen.include?(value.object_id)

          seen = seen.dup.add(value.object_id)
          copy = value.clone(freeze: false).clear
          if value.is_a?(Hash)
            raise UnsafeFilterMetadata if value.default_proc

            unless value.default.nil?
              copy.default = snapshot_filter_metadata(value.default, seen, depth + 1, budget, copies)
            end
            value.each do |key, item|
              unless key.is_a?(String) || key.is_a?(Symbol) || key.is_a?(Numeric) ||
                     key.nil? || key == true || key == false
                raise UnsafeFilterMetadata
              end

              copied_key = snapshot_filter_metadata(key, seen, depth + 1, budget, copies)
              copy[copied_key] = snapshot_filter_metadata(item, seen, depth + 1, budget, copies)
            end
          else
            value.each { |item| copy << snapshot_filter_metadata(item, seen, depth + 1, budget, copies) }
          end
          copy.freeze if value.frozen?
          copies[value] ||= copy
        when String, Symbol
          size = value.is_a?(String) ? value.bytesize : value.to_s.bytesize
          raise UnsafeFilterMetadata if size > MAX_STRING_LENGTH || size > budget[:bytes]

          budget[:bytes] -= size
          return value if value.is_a?(Symbol)

          copies[value] ||= value.clone
        when nil, true, false, Numeric
          value
        else
          copies[value] ||= value.clone
        end
      end

      def execution_context_properties
        unless defined?(ActiveSupport::ExecutionContext) && ActiveSupport::ExecutionContext.respond_to?(:to_h)
          return EMPTY_HASH
        end

        context = filtered_metadata(ActiveSupport::ExecutionContext.to_h)
        context.empty? ? EMPTY_HASH : { '$execution_context' => context }
      rescue StandardError
        EMPTY_HASH
      end

      def serialize_string(str, budget)
        length = [MAX_STRING_LENGTH, budget[:bytes]].min
        result = str.byteslice(0, length).dup.force_encoding(Encoding::UTF_8).scrub
        budget[:bytes] -= result.bytesize
        result
      end

      def serialize_array(array, seen, depth, budget)
        return '[circular reference]' if seen.include?(array.object_id)

        seen = seen.dup.add(array.object_id)
        array.first(100).each_with_object([]) do |item, result|
          break if budget[:bytes] <= 0 || budget[:nodes] <= 0

          result << safe_serialize(item, seen, depth + 1, budget)
        end
      end

      def serialize_hash(hash, seen, depth, budget)
        return '[circular reference]' if seen.include?(hash.object_id)

        seen = seen.dup.add(hash.object_id)
        result = {}
        hash.first(100).each do |key, val|
          break if budget[:bytes] <= 0 || budget[:nodes] <= 0

          result[serialize_string(key.to_s, budget)] = safe_serialize(val, seen, depth + 1, budget)
        end
        result
      end

      def serialize_object(obj, seen)
        return '[circular reference]' if seen.include?(obj.object_id)

        return obj.to_global_id.to_s if obj.respond_to?(:to_global_id)

        # For ActiveRecord and similar objects, use id if available
        return "#{obj.class.name}##{obj.id}" if obj.respond_to?(:id)

        "[#{obj.class.name}]"
      rescue StandardError
        "[#{obj.class.name}]"
      end
    end
  end
end
