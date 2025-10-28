# frozen_string_literal: true

module PostHog
  module Rails
    # Rails 7.0+ error reporter integration
    # This integrates with Rails.error.handle and Rails.error.record
    class ErrorSubscriber
      def report(error, handled:, severity:, context:, source: nil)
        return unless PostHog.rails_config&.auto_capture_exceptions
        return unless PostHog.rails_config&.should_capture_exception?(error)

        distinct_id = context[:user_id] || context[:distinct_id]

        properties = {
          '$exception_source' => source || 'rails_error_reporter',
          '$exception_handled' => handled,
          '$exception_severity' => severity
        }

        # Add context information
        if context.present?
          context.each do |key, value|
            properties["$context_#{key}"] = value unless key.in?([:user_id, :distinct_id])
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
