# frozen_string_literal: true

require 'posthog/internal/context'
require 'posthog/rails/tracing_headers'

module PostHog
  module Rails
    # Rack middleware that creates a request-local PostHog context from tracing headers.
    class RequestContext
      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) if PostHog::Rails.config&.capture_request_context == false

        request = build_request(env)

        Internal::Context.with_context(context_data(request), fresh: true) do
          @app.call(env)
        end
      end

      private

      def context_data(request)
        session_id = tracing_header(request, 'X-POSTHOG-SESSION-ID')
        distinct_id = tracing_header(request, 'X-POSTHOG-DISTINCT-ID')

        {
          distinct_id: distinct_id,
          session_id: session_id,
          properties: request_properties(request)
        }
      end

      def request_properties(request)
        properties = {}
        add_property(properties, '$current_url', request_value(request, :url))
        request_method = request_value(request, :request_method) || request_value(request, :method)
        add_property(properties, '$request_method', request_method)
        add_property(properties, '$request_path', request_value(request, :path) || request_value(request, :path_info))
        add_property(properties, '$user_agent', tracing_header(request, 'User-Agent'))
        add_property(properties, '$ip', client_ip(request))
        properties
      end

      def client_ip(request)
        trusted_ip = request_value(request, :remote_ip) || request_value(request, :ip)
        return trusted_ip if present?(trusted_ip)

        forwarded_for = tracing_header(request, 'X-Forwarded-For')
        forwarded_ip = forwarded_for.split(',').first&.strip if forwarded_for
        return forwarded_ip if present?(forwarded_ip)

        env_value(request, 'REMOTE_ADDR')
      end

      def present?(value)
        !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
      end

      def add_property(properties, key, value)
        return if value.nil?

        serialized = value.to_s
        return if serialized.empty?

        properties[key] = serialized
      end

      def tracing_header(request, header_name)
        TracingHeaders.extract_header(request, header_name)
      end

      def request_value(request, method_name)
        return unless request.respond_to?(method_name)

        request.public_send(method_name)
      rescue StandardError
        nil
      end

      def env_value(request, key)
        request.respond_to?(:get_header) ? request.get_header(key) : request.env[key]
      rescue StandardError
        nil
      end

      def build_request(env)
        if defined?(ActionDispatch::Request)
          ActionDispatch::Request.new(env)
        elsif defined?(Rack::Request)
          Rack::Request.new(env)
        else
          env
        end
      end
    end
  end
end
