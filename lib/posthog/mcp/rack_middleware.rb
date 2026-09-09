# frozen_string_literal: true

require 'json'
require 'stringio'

module PostHog
  module MCP
    # Rack middleware for stateless / multi-pod MCP servers built on a custom
    # Rack stack (not the `mcp` gem's Streamable HTTP transport, which
    # {PostHog::MCP.instrument} wires automatically).
    #
    # At `initialize`, when the client sent no `Mcp-Session-Id`, it mints a
    # self-encoded session token onto the response header; clients replay it
    # on every request so any pod recovers `$session_id` and the client identity
    # from the header alone. The decoded token (if any) is exposed to the app as
    # `env['posthog_mcp.session']` ({SessionTokenPayload}).
    #
    # @note Experimental.
    #
    # @example
    #   use PostHog::MCP::RackMiddleware
    class RackMiddleware
      ENV_KEY = 'posthog_mcp.session'
      MAX_SNIFF_BODY = 256 * 1024

      def initialize(app)
        @app = app
      end

      def call(env)
        incoming = SessionToken.read_header(MCP_SESSION_HEADER => env['HTTP_MCP_SESSION_ID'])
        decoded = SessionToken.decode(incoming)
        env[ENV_KEY] = decoded if decoded

        token = nil
        if env['REQUEST_METHOD'] == 'POST' && incoming.nil?
          token = begin
            mint_token_if_initialize(read_body(env))
          rescue StandardError => e
            Log.debug(nil, "PostHog MCP session middleware: mint failed - #{e.message}")
            nil
          end
          env[ENV_KEY] = SessionToken.decode(token) if token
        end

        status, headers, body = @app.call(env)
        # Only a successful initialize gets the token, so a client cannot replay a
        # session minted for a handshake the server rejected.
        if token && success?(status) && headers.respond_to?(:key?) &&
           headers.keys.none? { |k| k.to_s.casecmp?(MCP_SESSION_HEADER) }
          headers[MCP_SESSION_HEADER] = token
        elsif token && !decoded
          env.delete(ENV_KEY)
        end
        [status, headers, body]
      end

      private

      def success?(status)
        status.to_i.between?(200, 299)
      end

      # Reads the request body (bounded) and makes it re-readable for the app.
      def read_body(env)
        input = env['rack.input']
        return '' unless input.respond_to?(:read)

        body = input.read(MAX_SNIFF_BODY + 1) || ''
        if input.respond_to?(:rewind)
          input.rewind
        else
          rest = input.read || ''
          env['rack.input'] = StringIO.new(body + rest)
        end
        body.bytesize > MAX_SNIFF_BODY ? '' : body
      end

      def mint_token_if_initialize(body)
        return nil if body.nil? || body.empty?

        message = parse_json(body)
        return nil unless message.is_a?(Hash) && message['method'] == 'initialize'

        params = message['params'].is_a?(Hash) ? message['params'] : {}
        client_info = params['clientInfo'].is_a?(Hash) ? params['clientInfo'] : {}
        protocol_version = params['protocolVersion']
        return nil unless Instrumentation.legacy_era?(protocol_version)

        SessionToken.encode(
          SessionTokenPayload.new(
            session_id: Session.new_session_id,
            client_name: string_or_nil(client_info['name']),
            client_version: string_or_nil(client_info['version']),
            protocol_version: string_or_nil(protocol_version)
          )
        )
      end

      def parse_json(body)
        JSON.parse(body)
      rescue StandardError
        nil
      end

      def string_or_nil(value)
        value.is_a?(String) && !value.empty? ? value : nil
      end
    end
  end
end
