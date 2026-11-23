# frozen_string_literal: true

require 'posthog/rails/parameter_filter'
require 'posthog/rails/request_metadata'

module PostHog
  module Rails
    # Shared request enrichment for automatic and manual exception capture.
    #
    # @api private
    class ExceptionContext
      include ParameterFilter

      def initialize(request, controller = request.env['action_controller.instance'], manual: false)
        @request = request
        @controller = controller
        @manual = manual
      end

      def distinct_id
        # Prefer authenticated Rails user context. Request/tracing context is
        # applied later by the core capture path if this returns nil.
        return nil unless PostHog::Rails.config&.capture_user_context

        user = extract_current_user(@controller)
        user_id = extract_user_id(user) if user
        return user_id if present?(user_id)

        nil
      rescue StandardError
        raise unless @manual

        nil
      end

      def properties
        request = @request
        env = request.env
        properties = @manual ? RequestMetadata.extract(request) : {}

        # Add controller and action if available
        if @controller
          controller = @controller
          properties['$controller'] = safe_serialize(controller.controller_name)
          properties['$action'] = safe_serialize(controller.action_name)
        end

        # Add request parameters (be careful with sensitive data)
        params = request_parameters
        if params.present?
          filtered_params = filter_request_parameters(params)
          # Safe serialize to handle any complex objects in params
          properties['$request_params'] = safe_serialize(filtered_params) unless filtered_params.empty?
        end

        status = env['posthog.response_status_code']
        status ||= @controller.response.status if @manual && @controller&.performed?
        properties['$response_status_code'] = status if status

        # Add referrer
        properties['$referrer'] = safe_serialize(request.referrer) if request.referrer

        if @manual
          %w[$current_url $referrer].each do |key|
            properties[key] = properties[key].split(/[?#]/, 2).first if properties[key]
          end
        end

        properties
      rescue StandardError
        raise unless @manual

        {}
      end

      private

      def request_parameters
        return @request.params unless @manual

        # Only Rails-owned parsed caches are safe to read without invoking body-parser diagnostics.
        cached = @request.get_header('action_dispatch.request.parameters')
        return cached if cached.is_a?(Hash)

        body = @request.get_header('action_dispatch.request.request_parameters')
        body = {} unless body.is_a?(Hash)
        body.merge(@request.query_parameters).merge(@request.path_parameters)
      rescue StandardError
        raise unless @manual

        {}
      end

      def filter_request_parameters(params)
        if @manual && @request.has_header?('action_dispatch.parameter_filter')
          ParameterFilter.backend.new(@request.get_header('action_dispatch.parameter_filter')).filter(params)
        else
          filter_sensitive_params(params)
        end
      end

      def extract_current_user(controller)
        resolver = PostHog::Rails.config&.current_user_resolver
        return resolve_current_user(resolver, controller) if resolver

        method_name = PostHog::Rails.config&.current_user_method || :current_user
        return unless controller.respond_to?(method_name, true)

        controller.send(method_name)
      end

      def resolve_current_user(resolver, controller)
        call_current_user_resolver(resolver, controller)
      rescue StandardError => e
        message = @manual ? 'current_user_resolver failed' : "current_user_resolver failed: #{e.message}"
        PostHog::Logging.logger.warn(message)
        nil
      end

      def call_current_user_resolver(resolver, controller)
        if resolver.arity.zero?
          controller ? controller.instance_exec(&resolver) : resolver.call
        elsif controller
          resolver.call(controller)
        end
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

      def present?(value)
        !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
      end
    end

    private_constant :ExceptionContext
  end
end
