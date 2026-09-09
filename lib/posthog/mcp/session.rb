# frozen_string_literal: true

module PostHog
  module MCP
    # Session id resolution, in priority order: the
    # agent's echoed `conversation_id` handle first, then our self-encoded
    # session token, then the transport's MCP session id, then this server's own
    # memory (which rolls over after {INACTIVITY_TIMEOUT_MINUTES} of inactivity).
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

      # @return [Array(String, String)] `[session_id, source]` where source is one of
      #   `conversation`, `token`, `mcp`, `generated`
      def resolve(data, mcp_session_id, token: nil, conversation_id: nil)
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
