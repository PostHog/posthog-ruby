# frozen_string_literal: true

module PostHog
  module Internal
    class SpanContext
      def self.apply(span)
        context = Context.current
        return unless context && span&.recording? && span.respond_to?(:attributes)

        attributes = span.attributes || {}
        {
          'posthogDistinctId' => context.distinct_id,
          'sessionId' => context.session_id
        }.each do |key, value|
          next if value.nil? || value == '' || attributes.key?(key)

          span.set_attribute(key, value.is_a?(String) ? value.dup.freeze : value)
        end
      rescue StandardError
        nil
      end

      def self.apply_current
        return unless defined?(::OpenTelemetry::Trace)

        apply(::OpenTelemetry::Trace.current_span)
      rescue StandardError
        nil
      end
    end
  end
end
