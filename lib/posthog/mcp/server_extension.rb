# frozen_string_literal: true

module PostHog
  module MCP
    # Prepended onto `MCP::Server` once. Wraps the dispatch lambda that
    # `handle_request` returns for instrumented servers so {Instrumentation}
    # runs around the real handler with the raw request, params, and session.
    # Uninstrumented servers fall straight through to `super`.
    #
    # @api private
    module ServerExtension
      private

      def handle_request(request, method, session: nil, related_request_id: nil)
        handler = super
        data = PostHog::MCP.tracking_data(self)
        return handler unless data && handler.is_a?(Proc) && Instrumentation.tracked?(method)

        lambda do |params|
          instrumentation = Instrumentation.new(
            self, data,
            method: method, request: request, params: params, session: session, request_id: related_request_id
          )
          instrumentation.dispatch { handler.call(params) }
        end
      end
    end

    # Prepended onto `MCP::Server::Transports::StreamableHTTPTransport` once.
    # Publishes the HTTP headers of the in-flight request to {RequestScope} and
    # adds the `Mcp-Session-Id` token minted by {Instrumentation} on stateless
    # `initialize` responses.
    #
    # @api private
    module TransportExtension
      HEADER_ENV_KEYS = {
        'user-agent' => 'HTTP_USER_AGENT',
        'x-anthropic-client' => 'HTTP_X_ANTHROPIC_CLIENT',
        'mcp-session-id' => 'HTTP_MCP_SESSION_ID',
        'mcp-protocol-version' => 'HTTP_MCP_PROTOCOL_VERSION'
      }.freeze

      def handle_request(request)
        server = instance_variable_defined?(:@server) ? @server : nil
        return super unless server && PostHog::MCP.tracking_data(server)

        env = request.respond_to?(:env) ? request.env : {}
        headers = HEADER_ENV_KEYS.each_with_object({}) do |(name, env_key), acc|
          value = env[env_key]
          acc[name] = value if value.is_a?(String) && !value.empty?
        end

        RequestScope.with(headers: headers) do |scope|
          response = super
          mint = scope[:mint]
          if mint && response.is_a?(Array) && response[1].is_a?(Hash) &&
             response[1].keys.none? { |key| key.to_s.casecmp?(MCP_SESSION_HEADER) }
            response[1][MCP_SESSION_HEADER] = mint
          end
          response
        end
      end
    end
  end
end
