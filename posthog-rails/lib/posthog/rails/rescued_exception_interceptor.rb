# frozen_string_literal: true

module PostHog
  module Rails
    # Middleware that intercepts exceptions that are rescued by Rails
    # This middleware runs before ShowExceptions and captures the exception
    # so we can report it even if Rails rescues it
    class RescuedExceptionInterceptor
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      rescue StandardError => e
        # Store the exception so CaptureExceptions middleware can report it
        env['posthog.rescued_exception'] = e if should_intercept?
        raise e
      end

      private

      def should_intercept?
        PostHog::Rails.config&.report_rescued_exceptions
      end
    end
  end
end
