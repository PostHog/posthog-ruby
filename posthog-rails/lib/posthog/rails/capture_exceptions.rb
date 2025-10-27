# frozen_string_literal: true

require 'posthog/rails/parameter_filter'

module PostHog
  module Rails
    # Middleware that captures exceptions and sends them to PostHog
    class CaptureExceptions
      include ParameterFilter

      def initialize(app)
        @app = app
      end

      def call(env)
        response = @app.call(env)

        # Check if there was an exception that Rails handled
        exception = collect_exception(env)

        if exception && should_capture?(exception)
          capture_exception(exception, env)
        end

        response
      rescue StandardError => exception
        # Capture unhandled exceptions
        capture_exception(exception, env) if should_capture?(exception)
        raise
      end

      private

      def collect_exception(env)
        # Rails stores exceptions in these env keys
        exception = env['action_dispatch.exception'] ||
          env['rack.exception'] ||
          env['posthog.rescued_exception']

        exception
      end

      def should_capture?(exception)
        return false unless PostHog.rails_config&.auto_capture_exceptions
        return false unless PostHog.rails_config&.should_capture_exception?(exception)

        true
      end

      def capture_exception(exception, env)
        request = ActionDispatch::Request.new(env)
        distinct_id = extract_distinct_id(env, request)
        additional_properties = build_properties(request, env)

        PostHog.capture_exception(exception, distinct_id, additional_properties)
      rescue StandardError => e
        PostHog::Logging.logger.error("Failed to capture exception: #{e.message}")
        PostHog::Logging.logger.error("Backtrace: #{e.backtrace&.first(5)&.join("\n")}")
      end

      def extract_distinct_id(env, request)
        # Try to get user from controller
        if env['action_controller.instance']
          controller = env['action_controller.instance']
          method_name = PostHog.rails_config&.current_user_method || :current_user

          if controller.respond_to?(method_name, true)
            user = controller.send(method_name)
            return extract_user_id(user) if user
          end
        end

        # Fallback to session ID or nil
        request.session_options&.dig(:id)
      end

      def extract_user_id(user)
        # Try common ID methods
        return user.id if user.respond_to?(:id)
        return user['id'] if user.respond_to?(:[]) && user['id']
        return user.uuid if user.respond_to?(:uuid)
        return user['uuid'] if user.respond_to?(:[]) && user['uuid']
        user.to_s
      end

      def build_properties(request, env)
        properties = {
          '$exception_source' => 'rails',
          '$request_url' => request.url,
          '$request_method' => request.method,
          '$request_path' => request.path
        }

        # Add controller and action if available
        if env['action_controller.instance']
          controller = env['action_controller.instance']
          properties['$controller'] = controller.controller_name
          properties['$action'] = controller.action_name
        end

        # Add request parameters (be careful with sensitive data)
        if request.params.present?
          filtered_params = filter_sensitive_params(request.params)
          properties['$request_params'] = filtered_params unless filtered_params.empty?
        end

        # Add user agent
        properties['$user_agent'] = request.user_agent if request.user_agent

        # Add referrer
        properties['$referrer'] = request.referrer if request.referrer

        properties
      end

      def filter_sensitive_params(params)
        # Use Rails' configured filter_parameters to filter sensitive data
        # This respects the app's config.filter_parameters setting
        filtered = super(params)

        # Also truncate long values
        filtered.transform_values do |value|
          if value.is_a?(String) && value.length > 1000
            "#{value[0..1000]}... (truncated)"
          else
            value
          end
        end
      rescue StandardError
        {} # Return empty hash if filtering fails
      end
    end
  end
end
