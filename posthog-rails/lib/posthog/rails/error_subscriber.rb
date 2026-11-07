# frozen_string_literal: true

require 'posthog/rails/parameter_filter'

module PostHog
  module Rails
    # Rails 7.0+ error reporter integration.
    # This integrates with Rails.error.handle and Rails.error.record.
    #
    # @api private
    class ErrorSubscriber
      include ParameterFilter

      # @param error [Exception] Error reported by Rails.
      # @param handled [Boolean]
      # @param severity [Symbol, String]
      # @param context [Hash]
      # @param source [String, nil]
      # @return [void]
      def report(error, handled:, severity:, context:, source: nil)
        return unless PostHog::Rails.config&.auto_capture_exceptions

        runner_report = !handled && source == 'application.runner.railties'
        return unless runner_report || PostHog::Rails.config&.should_capture_exception?(error)

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

        # Keep the reporter's object and serialized context until terminal capture.
        if runner_report
          Thread.current[:posthog_rails_runner_report] = [error, distinct_id, properties]
          return
        end

        PostHog.capture_exception(
          error,
          distinct_id,
          properties,
          mechanism: { 'type' => 'rails_error_reporter', 'handled' => handled }
        )
      rescue StandardError => e
        PostHog::Logging.logger.error("Failed to report error via subscriber: #{e.message}")
        PostHog::Logging.logger.error("Backtrace: #{e.backtrace&.first(5)&.join("\n")}")
      end

      def self.take_runner_report(exception)
        report = Thread.current[:posthog_rails_runner_report]
        Thread.current[:posthog_rails_runner_report] = nil
        return unless report
        return report if report.first.equal?(exception)

        # Only Rails' inline command conversion may replace the reported object.
        original = report.first
        return unless exception.is_a?(SystemExit) && exception.status == 1
        return unless original.is_a?(NameError) || original.is_a?(SyntaxError)
        return unless exception.cause.equal?(original)
        return unless defined?(::Rails::Command::RunnerCommand)
        return unless exception.backtrace_locations&.first&.path ==
                      ::Rails::Command::RunnerCommand.instance_method(:perform).source_location.first

        report
      end
    end
  end
end
