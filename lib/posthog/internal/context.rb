# frozen_string_literal: true

module PostHog
  module Internal
    # Internal request/fiber-local context applied to capture calls.
    #
    # This is intentionally not exposed as a public SDK API in Ruby yet. It exists
    # to let framework integrations such as posthog-rails propagate request-scoped
    # tracing headers to regular capture and exception events without making the
    # server-side SDK globally stateful per user.
    class Context
      STORAGE_KEY = :posthog_context

      attr_reader :distinct_id, :session_id, :properties

      def initialize(distinct_id: nil, session_id: nil, properties: {})
        @distinct_id = distinct_id
        @session_id = session_id
        @properties = properties ? properties.dup : {}
        apply_session_property!
      end

      def self.current
        Thread.current[STORAGE_KEY]
      end

      def self.current=(context)
        Thread.current[STORAGE_KEY] = context
      end

      def self.with_context(data = nil, fresh: false, **kwargs)
        previous_context = current
        raise ArgumentError, 'with_context requires a block' unless block_given?

        self.current = resolve(merge_data_and_kwargs(data, kwargs), previous_context, fresh: fresh)
        yield
      ensure
        self.current = previous_context
      end

      def self.resolve(data, parent, fresh: false)
        data = normalize_data(data)

        parent_properties = fresh || parent.nil? ? {} : parent.properties
        properties = merge_properties(parent_properties, data[:properties] || {})
        if data[:session_id] && !session_property_key?(data[:properties])
          properties.delete('$session_id')
          properties.delete(:$session_id)
        end

        new(
          distinct_id: data[:distinct_id] || (fresh || parent.nil? ? nil : parent.distinct_id),
          session_id: data[:session_id] || (fresh || parent.nil? ? nil : parent.session_id),
          properties: properties
        )
      end
      private_class_method :resolve

      def self.merge_data_and_kwargs(data, kwargs)
        data ||= {}
        raise ArgumentError, 'context data must be a Hash' unless data.is_a?(Hash)

        data.merge(kwargs)
      end
      private_class_method :merge_data_and_kwargs

      def self.merge_properties(base, overrides)
        merged = (base || {}).dup
        (overrides || {}).each do |key, value|
          merged.delete(key.to_s) if key.is_a?(Symbol)
          merged.delete(key.to_sym) if key.is_a?(String)
          merged[key] = value
        end
        merged
      end

      def self.normalize_data(data)
        data ||= {}
        raise ArgumentError, 'context data must be a Hash' unless data.is_a?(Hash)

        properties = data[:properties] || data['properties'] || {}
        raise ArgumentError, 'context properties must be a Hash' unless properties.is_a?(Hash)

        {
          distinct_id: data[:distinct_id] || data['distinct_id'] || data[:distinctId] || data['distinctId'],
          session_id: data[:session_id] || data['session_id'] || data[:sessionId] || data['sessionId'],
          properties: properties
        }
      end
      private_class_method :normalize_data

      def self.session_property_key?(properties)
        return false unless properties.is_a?(Hash)

        properties.key?('$session_id') || properties.key?(:$session_id)
      end
      private_class_method :session_property_key?

      def apply_session_property!
        return if session_id.nil? || properties.key?('$session_id') || properties.key?(:$session_id)

        properties['$session_id'] = session_id
      end
      private :apply_session_property!
    end
  end

  private_constant :Internal
end
