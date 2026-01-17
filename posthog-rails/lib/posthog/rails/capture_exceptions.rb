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
          method_name = PostHog::Rails.config&.current_user_method || :current_user

          if controller.respond_to?(method_name, true)
            user = controller.send(method_name)
            return extract_user_id(user) if user
          end
        end

        # Fallback to session ID or nil
        request.session&.id
      end

      def extract_user_id(user)
        # Use configured method if specified
        method_name = PostHog::Rails.config&.user_id_method
        return user.send(method_name) if method_name && user.respond_to?(method_name)

        # Try explicit PostHog method (allows users to customize without config)
        return user.posthog_distinct_id if user.respond_to?(:posthog_distinct_id)
        return user.distinct_id if user.respond_to?(:distinct_id)

        # Try common ID methods
        return user.id if user.respond_to?(:id)
        return user['id'] if user.respond_to?(:[]) && user['id']
        return user.pk if user.respond_to?(:pk)
        return user['pk'] if user.respond_to?(:[]) && user['pk']
        return user.uuid if user.respond_to?(:uuid)
        return user['uuid'] if user.respond_to?(:[]) && user['uuid']

        user.to_s
      end

      def build_properties(request, env)
        properties = {
          '$exception_source' => 'rails',
          '$request_url' => safe_serialize(request.url),
          '$request_method' => safe_serialize(request.method),
          '$request_path' => safe_serialize(request.path)
        }

        # Add controller and action if available
        if env['action_controller.instance']
          controller = env['action_controller.instance']
          properties['$controller'] = safe_serialize(controller.controller_name)
          properties['$action'] = safe_serialize(controller.action_name)
        end

        # Add request parameters (be careful with sensitive data)
        if request.params.present?
          filtered_params = filter_sensitive_params(request.params)
          # Safe serialize to handle any complex objects in params
          properties['$request_params'] = safe_serialize(filtered_params) unless filtered_params.empty?
        end

        # Add user agent
        properties['$user_agent'] = safe_serialize(request.user_agent) if request.user_agent

        # Add referrer
        properties['$referrer'] = safe_serialize(request.referrer) if request.referrer

        properties
      end
    end
  end
end
