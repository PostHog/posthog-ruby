# frozen_string_literal: true

require 'posthog/internal/context'
require 'posthog/rails/tracing_headers'
require 'posthog/rails/request_metadata'

module PostHog
  module Rails
    # Rack middleware that creates a request-local PostHog context from tracing headers.
    #
    # @api private
    class RequestContext
      # @param app [#call] Rack application.
      def initialize(app)
        @app = app
      end

      # @param env [Hash] Rack environment.
      # @return [Array] Rack response.
      def call(env)
        request = build_request(env)

        Internal::Context.with_context(context_data(request), fresh: true) do
          @app.call(env)
        end
      end

      private

      def context_data(request)
        data = { properties: request_properties(request) }
        return data unless use_tracing_headers?

        data.merge(
          distinct_id: tracing_header(request, 'X-POSTHOG-DISTINCT-ID'),
          session_id: tracing_header(request, 'X-POSTHOG-SESSION-ID')
        )
      end

      def use_tracing_headers?
        PostHog::Rails.config&.use_tracing_headers != false
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
