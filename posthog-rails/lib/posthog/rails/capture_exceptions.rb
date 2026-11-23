# frozen_string_literal: true

require 'posthog/rails/exception_context'

module PostHog
  module Rails
    # Middleware that captures exceptions and sends them to PostHog.
    #
    # @api private
    class CaptureExceptions
      # @param app [#call] Rack application.
      def initialize(app)
        @app = app
      end

      # @param env [Hash] Rack environment.
      # @return [Array] Rack response.
      def call(env)
        response = @app.call(env)
        env['posthog.response_status_code'] = response_status(response)

        # Check if there was an exception that Rails handled
        exception = collect_exception(env)

        capture_exception(exception, env) if exception && should_capture?(exception)

        response
      rescue StandardError => e
        # Capture unhandled exceptions
        capture_exception(e, env) if should_capture?(e)
        raise
      end

      private

      def collect_exception(env)
        # Rails stores exceptions in these env keys
        env['action_dispatch.exception'] ||
          env['rack.exception'] ||
          env['posthog.rescued_exception']
      end

      def should_capture?(exception)
        return false unless PostHog::Rails.config&.auto_capture_exceptions
        return false unless PostHog::Rails.config&.should_capture_exception?(exception)

        true
      end

      def capture_exception(exception, env)
        request = ActionDispatch::Request.new(env)
        context = ExceptionContext.new(request)
        distinct_id = context.distinct_id
        additional_properties = { '$exception_source' => 'rails' }.merge(context.properties)

        PostHog.capture_exception(
          exception,
          distinct_id,
          additional_properties,
          mechanism: { 'type' => 'rails', 'handled' => false }
        )
      rescue StandardError => e
        PostHog::Logging.logger.error("Failed to capture exception: #{e.message}")
        PostHog::Logging.logger.error("Backtrace: #{e.backtrace&.first(5)&.join("\n")}")
      end

      def response_status(response)
        status = response.respond_to?(:[]) ? response[0] : nil
        status if status.is_a?(Integer)
      end
    end
  end
end
