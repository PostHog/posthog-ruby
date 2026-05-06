# frozen_string_literal: true

require 'posthog/internal/context'
require 'posthog/rails/parameter_filter'
require 'posthog/rails/request_metadata'

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
        # Prefer authenticated Rails user context over client-supplied tracing headers.
        if PostHog::Rails.config&.capture_user_context && env['action_controller.instance']
          controller = env['action_controller.instance']
          method_name = PostHog::Rails.config&.current_user_method || :current_user

          if controller.respond_to?(method_name, true)
            user = controller.send(method_name)
            user_id = extract_user_id(user) if user
            return user_id if present?(user_id)
          end
        end

        context_distinct_id = Internal::Context.current&.distinct_id
        return context_distinct_id if present?(context_distinct_id)

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
          '$exception_source' => 'rails'
        }.merge(request_metadata_properties(request))

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

        response_status_code = env['posthog.response_status_code']
        properties['$response_status_code'] = response_status_code if response_status_code

        # Add referrer
        properties['$referrer'] = safe_serialize(request.referrer) if request.referrer

        properties
      end

      REQUEST_METADATA_KEYS = %w[
        $current_url
        $request_method
        $request_path
        $user_agent
        $ip
      ].freeze
      private_constant :REQUEST_METADATA_KEYS

      def request_metadata_properties(request)
        # When RequestContext is active, regular capture context already owns and
        # applies these request properties. Fall back to direct extraction only
        # when that context is unavailable, e.g. if capture_request_context is disabled.
        return {} if request_metadata_in_context?

        RequestMetadata.extract(request)
      end

      def request_metadata_in_context?
        properties = Internal::Context.current&.properties
        return false unless properties.is_a?(Hash)

        REQUEST_METADATA_KEYS.any? { |key| properties.key?(key) || properties.key?(key.to_sym) }
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
