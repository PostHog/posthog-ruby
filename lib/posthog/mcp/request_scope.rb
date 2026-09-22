# frozen_string_literal: true

module PostHog
  module MCP
    # Request-scoped hand-off from the Streamable HTTP transport to the server
    # extension. The `mcp` gem re-parses the JSON body between
    # `StreamableHTTPTransport#handle_request` and `Server#handle_json`, so the
    # HTTP headers cannot travel with the request object; this is the one place
    # the integration relies on ambient state.
    #
    # Uses fiber storage (`Fiber[]`, Ruby 3.2+), which is per fiber, isolated per
    # Ractor, and inherited by fibers/threads a tool spawns. Falls back to
    # fiber-local `Thread.current[]` on Ruby 3.0/3.1.
    #
    # @api private
    module RequestScope
      KEY = :posthog_mcp_request_scope
      FIBER_STORAGE = Fiber.respond_to?(:[]) && Fiber.respond_to?(:[]=)

      # Rack `env` keys for the headers the integration reads, by header name.
      HEADER_ENV_KEYS = {
        'user-agent' => 'HTTP_USER_AGENT',
        'x-anthropic-client' => 'HTTP_X_ANTHROPIC_CLIENT',
        'mcp-session-id' => 'HTTP_MCP_SESSION_ID',
        'mcp-protocol-version' => 'HTTP_MCP_PROTOCOL_VERSION'
      }.freeze

      module_function

      # @return [Hash, nil] `{headers:, transport:, mint:, session_id:}` for the in-flight HTTP request,
      #   plus `actor:` once {Instrumentation} has resolved identity for it.
      #   `session_id` is the `$session_id` {Instrumentation} settled on before running the
      #   tool body, and `actor` the identity it resolved, so a custom event captured inside
      #   the tool is attributed to this request - to the right session and the right person -
      #   even while another request on the same server is in flight. `actor` is absent until
      #   the request resolves identity, which is what tells {Analytics} it has none to use.
      def current
        FIBER_STORAGE ? Fiber[KEY] : Thread.current[KEY]
      end

      def current=(value)
        if FIBER_STORAGE
          Fiber[KEY] = value
        else
          Thread.current[KEY] = value
        end
      end

      # @param headers [Hash{String => String}] lowercase header names
      # @param transport [Symbol] `:http` for the Streamable HTTP transport, `:other`
      #   for a transport that publishes no headers (stdio, a custom dispatcher)
      # @param env [Hash] a Rack `env`
      # @return [Hash{String => String}] the headers {Instrumentation} reads, lowercase
      def headers_from_env(env)
        return {} unless env.is_a?(Hash)

        HEADER_ENV_KEYS.each_with_object({}) do |(name, env_key), acc|
          value = env[env_key]
          acc[name] = value if value.is_a?(String) && !value.empty?
        end
      end

      def with(headers:, transport: :http)
        previous = current
        self.current = { headers: headers, transport: transport, mint: nil, session_id: nil }
        yield current
      ensure
        self.current = previous
      end
    end
  end
end
