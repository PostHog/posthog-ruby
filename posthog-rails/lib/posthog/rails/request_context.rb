# frozen_string_literal: true

require 'posthog/internal/context'
require 'posthog/rails/tracing_headers'
require 'posthog/rails/request_metadata'

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
        RequestMetadata.extract(request)
      end

      def tracing_header(request, header_name)
        TracingHeaders.extract_header(request, header_name)
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
