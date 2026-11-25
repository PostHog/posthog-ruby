# frozen_string_literal: true

module PostHog
  module MCP
    # Session id resolution, in priority order: the client's own conversation id,
    # the agent's echoed `conversation_id` handle, our self-encoded session token,
    # the transport's MCP session id, a session of its own for a request that
    # carries none over a transport shared by every client (stateless HTTP), and
    # last this server's own memory (which rolls over after
    # {INACTIVITY_TIMEOUT_MINUTES} of inactivity).
    #
    # @api private
    module Session
      module_function

      def new_session_id
        Ids.new_prefixed_id('ses')
      end

      def derive_session_id_from_mcp_session(mcp_session_id)
        Ids.deterministic_prefixed_id('ses', mcp_session_id)
      end

      # Deterministic, so every server that sees the same handle derives the same session.
      def derive_session_id_from_conversation(conversation_id)
        Ids.deterministic_prefixed_id('ses', conversation_id)
      end

      # A client conversation id and a handle name one chat, so they never touch
      # the server's shared state: a concurrent request would read them.
      #
      # @param client_conversation [String, nil] `"<_meta key>:<id>"`, see {ClientConversation.read}
      # @param request_session_id [String, nil] the session a request that carries
      #   none gets on a transport every client shares; never stored either
      # @return [Array(String, String)] `[session_id, source]` where source is one of
      #   `client_metadata`, `conversation`, `token`, `mcp`, `generated`
      def resolve(data, mcp_session_id, token: nil, conversation_id: nil, client_conversation: nil,
                  request_session_id: nil)
        if present?(client_conversation)
          return [derive_session_id_from_conversation(client_conversation), 'client_metadata']
        end
        return [derive_session_id_from_conversation(conversation_id), 'conversation'] if present?(conversation_id)

        data.synchronize do
          now = Time.now

          if token
            data.session_id = token.session_id
            data.session_source = 'token'
            data.last_activity = now
            return [data.session_id, 'token']
          end

          if present?(mcp_session_id)
            data.session_id = derive_session_id_from_mcp_session(mcp_session_id)
            data.last_mcp_session_id = mcp_session_id
            data.session_source = 'mcp'
            data.last_activity = now
            return [data.session_id, 'mcp']
          end

          return [request_session_id, 'generated'] if present?(request_session_id)

          if data.session_source == 'mcp' && data.last_mcp_session_id
            data.last_activity = now
            return [data.session_id, 'mcp']
          end

          stale = (now - data.last_activity) > (INACTIVITY_TIMEOUT_MINUTES * 60)
          if data.session_source != 'generated' || stale || data.session_id.nil?
            data.session_id = new_session_id
            data.session_source = 'generated'
          end
          data.last_activity = now
          [data.session_id, 'generated']
        end
      end

      def present?(value)
        value.is_a?(String) && !value.empty?
      end
      private_class_method :present?
    end
  end
end
