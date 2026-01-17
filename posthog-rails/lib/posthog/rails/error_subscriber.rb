# frozen_string_literal: true

require 'posthog/rails/parameter_filter'

module PostHog
  module Rails
    # Rails 7.0+ error reporter integration
    # This integrates with Rails.error.handle and Rails.error.record
    class ErrorSubscriber
      include ParameterFilter

      def report(error, handled:, severity:, context:, source: nil)
        return unless PostHog::Rails.config&.auto_capture_exceptions
        return unless PostHog::Rails.config&.should_capture_exception?(error)
        # Skip if in a web request - CaptureExceptions middleware will handle it
        # with richer context (URL, params, controller, etc.)
        return if PostHog::Rails.in_web_request?

        distinct_id = context[:user_id] || context[:distinct_id]

        properties = {
          '$exception_source' => source || 'rails_error_reporter',
          '$exception_handled' => handled,
          '$exception_severity' => severity.to_s
        }

        # Add context information (safely serialized to avoid circular references)
        if context.present?
          context.each do |key, value|
            next if key.in?(%i[user_id distinct_id])

            properties["$context_#{key}"] = safe_serialize(value)
          end
        end

        PostHog.capture_exception(error, distinct_id, properties)
      rescue StandardError => e
        PostHog::Logging.logger.error("Failed to report error via subscriber: #{e.message}")
        PostHog::Logging.logger.error("Backtrace: #{e.backtrace&.first(5)&.join("\n")}")
      end
    end
  end
end
