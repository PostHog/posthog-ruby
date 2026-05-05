# frozen_string_literal: true

require 'posthog/internal/context'
require 'posthog/rails/parameter_filter'
require 'posthog/rails/tracing_headers'

module PostHog
  module Rails
    # Middleware that captures exceptions and sends them to PostHog
    class CaptureExceptions
      include ParameterFilter

      def initialize(app)
        @app = app
      end

      def call(env)
        # Signal that we're in a web request context
        # ErrorSubscriber will skip capture for web requests to avoid duplicates
        PostHog::Rails.enter_web_request

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
      ensure
        PostHog::Rails.exit_web_request
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

      def extract_distinct_id(env, _request)
        context_distinct_id = Internal::Context.current&.distinct_id
        return context_distinct_id if present?(context_distinct_id)

        # Try to get user from controller if capture_user_context is enabled
        if PostHog::Rails.config&.capture_user_context && env['action_controller.instance']
          controller = env['action_controller.instance']
          method_name = PostHog::Rails.config&.current_user_method || :current_user

          if controller.respond_to?(method_name, true)
            user = controller.send(method_name)
            return extract_user_id(user) if user
          end
        end

        nil
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
          '$current_url' => safe_serialize(request.url),
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
        user_agent = TracingHeaders.sanitize_header_value(request.user_agent)
        properties['$user_agent'] = safe_serialize(user_agent) if user_agent

        ip_address = client_ip(request)
        properties['$ip'] = safe_serialize(ip_address) if ip_address

        response_status_code = env['posthog.response_status_code']
        properties['$response_status_code'] = response_status_code if response_status_code

        # Add referrer
        properties['$referrer'] = safe_serialize(request.referrer) if request.referrer

        properties
      end

      def client_ip(request)
        forwarded_for = TracingHeaders.extract_header(request, 'X-Forwarded-For')
        forwarded_ip = forwarded_for.split(',').first&.strip if forwarded_for
        return forwarded_ip if present?(forwarded_ip)

        request.remote_ip
      rescue StandardError
        nil
      end

      def response_status(response)
        status = response.respond_to?(:[]) ? response[0] : nil
        status if status.is_a?(Integer)
      end

      def present?(value)
        !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
      end
    end
  end
end
