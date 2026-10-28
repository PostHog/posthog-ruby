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

      # Rack `env` keys for the two request headers Rack stores without `HTTP_`.
      UNPREFIXED_HEADER_ENV_KEYS = { 'CONTENT_TYPE' => 'content-type', 'CONTENT_LENGTH' => 'content-length' }.freeze
      # The request line's protocol, which some servers (WEBrick, Thin) put in `env`.
      PROTOCOL_ENV_KEY = 'HTTP_VERSION'

      # Every request header, so `identify`, `intent_fallback` and `event_properties`
      # can read the ones they need (an `authorization` bearer token, an API key)
      # from `extra['headers']`. The SDK captures no header value: {Identity} keeps
      # only scalars from `extra`, and {TransportIdentity} stamps `user-agent` and
      # `x-anthropic-client` alone. A callback that returns a raw header value in
      # identity properties or `event_properties` sends it, unredacted.
      #
      # @param env [Hash] a Rack `env`
      # @return [Hash{String => String}] lowercase header names
      def headers_from_env(env)
        return {} unless env.is_a?(Hash)

        env.each_with_object({}) do |(key, value), acc|
          name = header_name(key)
          acc[name] = value if name && value.is_a?(String) && !value.empty?
        end
      end

      def header_name(env_key)
        return UNPREFIXED_HEADER_ENV_KEYS[env_key] unless env_key.is_a?(String) && env_key.start_with?('HTTP_')
        return nil if env_key == PROTOCOL_ENV_KEY

        env_key.delete_prefix('HTTP_').downcase.tr('_', '-')
      end

      # @param headers [Hash{String => String}] lowercase header names
      # @param transport [Symbol] `:http` for the Streamable HTTP transport, `:other`
      #   for a transport that publishes no headers (stdio, a custom dispatcher)
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
