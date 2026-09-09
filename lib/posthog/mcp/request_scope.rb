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

      # @return [Hash, nil] `{headers:, transport:, mint:}` for the in-flight HTTP request
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
      def with(headers:, transport: :http)
        previous = current
        self.current = { headers: headers, transport: transport, mint: nil }
        yield current
      ensure
        self.current = previous
      end
    end
  end
end
