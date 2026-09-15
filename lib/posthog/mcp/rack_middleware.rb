# frozen_string_literal: true

module PostHog
  module MCP
    # Rack middleware for stateless / multi-pod MCP servers built on a custom
    # Rack stack (not the `mcp` gem's Streamable HTTP transport, which
    # {PostHog::MCP.instrument} wires automatically).
    #
    # It publishes the request's headers to {RequestScope}, so an instrumented
    # `MCP::Server` dispatched anywhere below it sees the HTTP context the gem's
    # own transport would have given it, and it carries the `Mcp-Session-Id`
    # token minted at `initialize` back onto the response. Clients replay that
    # token on every request, so any pod recovers `$session_id` and the client
    # identity from the header alone.
    #
    # Neither the request nor the response body is read here. The token comes
    # from whoever handled the request and already knows it succeeded: the
    # instrumented server, or - for a hand-rolled dispatcher built on
    # {PostHog::MCP::Client} - a call to the mint hook this middleware exposes as
    # `env['posthog_mcp.mint']`.
    #
    # The decoded token (replayed or freshly minted) is exposed to the app as
    # `env['posthog_mcp.session']` ({SessionTokenPayload}).
    #
    # @note Experimental. `PostHog::MCP` is not officially supported; see the
    #   docs at https://posthog.com/docs/mcp-analytics.
    #
    # @example An instrumented server behind a custom Rack stack
    #   use PostHog::MCP::RackMiddleware
    #
    # @example A hand-rolled dispatcher minting the session itself
    #   session = env['posthog_mcp.mint']&.call(
    #     client_name: info['name'], client_version: info['version'], protocol_version: params['protocolVersion']
    #   )
    #   analytics.capture_initialize(session_id: session&.session_id, ...)
    class RackMiddleware
      ENV_KEY = 'posthog_mcp.session'
      MINT_ENV_KEY = 'posthog_mcp.mint'

      def initialize(app)
        @app = app
      end

      def call(env)
        replayed = SessionToken.decode(SessionToken.read_header(MCP_SESSION_HEADER => env['HTTP_MCP_SESSION_ID']))
        env[ENV_KEY] = replayed if replayed

        RequestScope.with(headers: RequestScope.headers_from_env(env), transport: :http) do |scope|
          env[MINT_ENV_KEY] = mint_hook(scope, env) unless replayed
          status, headers, body = @app.call(env)
          settle_token(scope[:mint], status, headers, env, replayed)
          [status, headers, body]
        ensure
          env.delete(MINT_ENV_KEY)
        end
      end

      private

      # A token is minted only once the handshake produced an `InitializeResult`,
      # so a rejected `initialize` - including a JSON-RPC error riding on a 200 -
      # mints nothing. The status check covers a hand-rolled dispatcher that
      # minted and then failed the request: the client never gets a session it
      # cannot use, and `env` stops advertising one.
      def settle_token(token, status, headers, env, replayed)
        return if token.nil?

        if success?(status) && attachable?(headers)
          headers[MCP_SESSION_HEADER] = token
          env[ENV_KEY] = SessionToken.decode(token)
        elsif !replayed
          env.delete(ENV_KEY)
        end
      end

      def success?(status)
        status.to_i.between?(200, 299)
      end

      def attachable?(headers)
        headers.respond_to?(:key?) && headers.keys.none? { |key| key.to_s.casecmp?(MCP_SESSION_HEADER) }
      end

      # `env['posthog_mcp.mint']`, for a dispatcher that handles `initialize`
      # itself: call it once the handshake is accepted to get the session this
      # request belongs to. Only present when the client replayed no token, and
      # nil for a modern-era client (protocol revision 2026-07-28 or later), which
      # must not be answered with an `Mcp-Session-Id`.
      #
      # @return [Proc] `(client_name:, client_version:, protocol_version:) -> SessionTokenPayload | nil`
      def mint_hook(scope, env)
        lambda do |client_name: nil, client_version: nil, protocol_version: nil|
          next env[ENV_KEY] if scope[:mint]
          next nil unless Instrumentation.legacy_era?(protocol_version)

          payload = SessionTokenPayload.new(
            session_id: Session.new_session_id,
            client_name: string_or_nil(client_name),
            client_version: string_or_nil(client_version),
            protocol_version: string_or_nil(protocol_version)
          )
          scope[:mint] = SessionToken.encode(payload)
          env[ENV_KEY] = payload
        end
      end

      def string_or_nil(value)
        value.is_a?(String) && !value.empty? ? value : nil
      end
    end
  end
end
