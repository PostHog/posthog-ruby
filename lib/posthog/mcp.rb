# frozen_string_literal: true

require 'posthog'

require 'posthog/mcp/constants'
require 'posthog/mcp/log'
require 'posthog/mcp/ids'
require 'posthog/mcp/options'
require 'posthog/mcp/session_token'
require 'posthog/mcp/session'
require 'posthog/mcp/identity'
require 'posthog/mcp/tools'
require 'posthog/mcp/exceptions'
require 'posthog/mcp/sanitization'
require 'posthog/mcp/truncation'
require 'posthog/mcp/conversation_id'
require 'posthog/mcp/intent'
require 'posthog/mcp/schema_mutation'
require 'posthog/mcp/event_builder'
require 'posthog/mcp/sink'
require 'posthog/mcp/tracking_data'
require 'posthog/mcp/request_scope'
require 'posthog/mcp/analytics'
require 'posthog/mcp/instrumentation'
require 'posthog/mcp/server_extension'
require 'posthog/mcp/rack_middleware'
require 'posthog/mcp/client'

module PostHog
  # PostHog MCP analytics for servers built on the official Ruby `mcp` gem.
  #
  # Wrap an `MCP::Server` so every tool call, handshake, listing, prompt,
  # resource read, and failure is captured to PostHog as a `$mcp_*` event.
  #
  # @note Experimental: the API and the captured event schema may change in a
  #   minor release. A warning is logged when this file is required.
  #
  # @example
  #   require 'posthog/mcp'
  #
  #   posthog = PostHog::Client.new(api_key: 'phc_...', host: 'https://us.i.posthog.com')
  #   server = MCP::Server.new(name: 'my-server', version: '1.0.0', tools: [MyTool])
  #   analytics = PostHog::MCP.instrument(server, posthog)
  #
  #   # With posthog-rails the client is resolved from PostHog.client:
  #   PostHog::MCP.instrument(server)
  module MCP
    EXPERIMENTAL_NOTICE =
      'PostHog::MCP is experimental: its API and the captured $mcp_* event schema may change in a minor ' \
      'release. Feedback welcome at https://github.com/PostHog/posthog-ruby/issues.'

    class << self
      # Instrument an `MCP::Server`.
      #
      # @param server [MCP::Server] the server to wrap
      # @param client [PostHog::Client, nil] the PostHog client to send through. Defaults to
      #   `PostHog.client` when the posthog-rails facade is loaded.
      # @param options [PostHog::MCP::Options, nil] prebuilt options; otherwise pass keywords
      # @param kwargs [Hash] {PostHog::MCP::Options} keywords (`identify:`, `before_send:`, ...)
      # @return [PostHog::MCP::Analytics] handle for custom events; a no-op handle when
      #   instrumentation fails (logged, never raised)
      # @raise [LoadError] when the `mcp` gem is not available
      def instrument(server, client = nil, options: nil, **kwargs)
        opts = options.is_a?(Options) ? options : Options.new(**kwargs)
        ensure_mcp_sdk!
        experimental_notice!(opts)

        begin
          unless server.is_a?(::MCP::Server)
            raise TypeError, "Unsupported server type: #{server.class}. Pass an MCP::Server."
          end

          existing = tracking_data(server)
          if existing
            Log.debug(opts, 'instrument() - server already instrumented, skipping initialization')
            return Analytics.new(server)
          end

          resolved_client = resolve_client(client)
          Log.warn(opts, 'Warning: no PostHog client available; MCP events will not be sent.') if resolved_client.nil?
          sink = resolved_client ? Sink.new(resolved_client) : nil
          data = TrackingData.new(options: opts, sink: sink, server_name: safe_call(server, :name),
                                  server_version: safe_call(server, :version))
          install_extensions!
          server.instance_variable_set(:@__posthog_mcp, data)
          register_missing_capability_tool(server, data)
          Analytics.new(server)
        rescue StandardError => e
          Log.warn(opts, "Warning: failed to instrument server - #{e.class}: #{e.message}")
          NoopAnalytics.new
        end
      end

      # @api private
      # @return [PostHog::MCP::TrackingData, nil]
      def tracking_data(server)
        return nil unless server.instance_variable_defined?(:@__posthog_mcp)

        server.instance_variable_get(:@__posthog_mcp)
      end

      # Encode a session token for a custom HTTP layer's `Mcp-Session-Id` response header.
      #
      # @param payload [PostHog::MCP::SessionTokenPayload, Hash]
      # @return [String]
      def encode_session_id(payload)
        SessionToken.encode(payload)
      end

      # Decode an `Mcp-Session-Id` value; nil for anything that is not one of our tokens.
      #
      # @return [PostHog::MCP::SessionTokenPayload, nil]
      def decode_session_id(value)
        SessionToken.decode(value)
      end

      # Deterministic `$session_id` for a transport session id (stable across restarts).
      #
      # @return [String]
      def derive_session_id_from_mcp_session(mcp_session_id)
        Session.derive_session_id_from_mcp_session(mcp_session_id)
      end

      # Deterministic `$session_id` for an agent conversation handle.
      #
      # @return [String]
      def derive_session_id_from_conversation(conversation_id)
        Session.derive_session_id_from_conversation(conversation_id)
      end

      # The canned `get_more_tools` result for custom dispatchers.
      #
      # @return [Hash]
      def get_more_tools_result # rubocop:disable Naming/AccessorMethodName -- public API name
        Tools.result
      end

      # @api private
      def mcp_sdk_available?
        defined?(::MCP::Server) ? true : false
      end

      # @api private
      def experimental_notice!(options = nil)
        Log.debug(options, EXPERIMENTAL_NOTICE)
        return if @experimental_notice_shown

        @experimental_notice_shown = true
        Kernel.warn("[posthog-ruby] #{EXPERIMENTAL_NOTICE}")
      end

      # @api private
      def reset_for_tests!
        @experimental_notice_shown = false
      end

      private

      def ensure_mcp_sdk!
        return if mcp_sdk_available?

        raise LoadError, "PostHog::MCP.instrument needs the MCP SDK. Add `gem 'mcp', '>= 1.4'` to your Gemfile. " \
                         '(PostHog::MCP::Client for custom dispatchers works without it.)'
      end

      def resolve_client(client)
        return client if client

        PostHog.respond_to?(:client) ? PostHog.client : nil
      rescue StandardError
        nil
      end

      def safe_call(object, method_name)
        object.respond_to?(method_name) ? object.public_send(method_name) : nil
      rescue StandardError
        nil
      end

      # Adds the `get_more_tools` virtual tool as a real server tool. An application
      # tool that already uses the name wins and is tracked as an ordinary tool.
      def register_missing_capability_tool(server, data)
        return unless data.options.report_missing

        name = Tools.missing_capability_tool_name(data.options)
        return if server.tools.is_a?(Hash) && server.tools.key?(name)

        data.virtual_tool = Tools.register(server, name, data.options)
      rescue StandardError => e
        Log.warn(data.options, "Warning: could not register the #{name} tool - #{e.class}: #{e.message}")
      end

      def install_extensions!
        return if @extensions_installed

        ::MCP::Server.prepend(ServerExtension)
        if defined?(::MCP::Server::Transports::StreamableHTTPTransport)
          ::MCP::Server::Transports::StreamableHTTPTransport.prepend(TransportExtension)
        end
        @extensions_installed = true
      end
    end
  end
end

begin
  require 'mcp'
rescue LoadError
  # The `mcp` gem is a peer dependency of PostHog::MCP.instrument; PostHog::MCP::Client
  # (custom dispatchers) works without it. `instrument` raises a LoadError with a hint.
end

PostHog::MCP.experimental_notice!
