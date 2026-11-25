# frozen_string_literal: true

module PostHog
  module MCP
    # Client conversation ids: the value an MCP client puts in a `tools/call`
    # request's `_meta` to name the conversation the call belongs to.
    #
    # {ROWS} is the table of the MCP analytics spec's "Session identity"
    # requirement, row for row, in its order. A row's key is read only from a
    # request its recognition rule matches, so a generic key such as Codex's
    # `sessionId` is never read from a client that means something else by it.
    # posthog-js and posthog-python keep the same table.
    #
    # @api private
    module ClientConversation
      # `handle_free`: the client sends its id on every call, so it is advertised
      # no `conversation_id` and minted no handle.
      Row = Struct.new(:key, :value, :user_agent, :client_names, :handle_free, keyword_init: true) do
        def recognizes?(user_agent, client_name)
          return true if user_agent.is_a?(String) && self.user_agent.match?(user_agent)

          client_name.is_a?(String) && client_names.any? { |name| name.casecmp?(client_name) }
        end

        # @return [String, nil] the id in `meta` when it is this row's shape
        def read(meta)
          id = meta[key] || meta[key.to_sym]
          ClientConversation.public_send(value, id) if id.is_a?(String)
        end
      end

      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
      NIL_UUID = '00000000-0000-0000-0000-000000000000'
      PRINTABLE_ASCII = /\A[\x20-\x7e]{1,128}\z/
      VSCODE_NAMES = ['Visual Studio Code', 'Visual Studio Code - Insiders'].freeze

      ROWS = [
        Row.new(key: 'openai/session', value: :printable_ascii, handle_free: true, client_names: [],
                user_agent: %r{\Aopenai-mcp/[^\s(]*\s*\(\s*chatgpt\s*[;,)]}i),
        Row.new(key: 'sessionId', value: :uuid, handle_free: false, client_names: ['codex-mcp-client'],
                user_agent: %r{\Acodex-mcp-client/}i),
        Row.new(key: 'vscode.conversationId', value: :uuid, handle_free: false, client_names: VSCODE_NAMES,
                user_agent: /\A(?:#{VSCODE_NAMES.map { |name| Regexp.escape("#{name}/") }.join('|')})/i)
      ].freeze

      module_function

      # @return [Row, nil] the first row that recognizes the request
      def recognize(user_agent, client_name)
        ROWS.find { |row| row.recognizes?(user_agent, client_name) }
      end

      # @return [String, nil] `"<key>:<id>"`, what the session is derived from
      def read(row, meta)
        return nil unless row && meta.is_a?(Hash)

        id = row.read(meta)
        id && "#{row.key}:#{id}"
      end

      def uuid(value)
        lowered = value.downcase
        lowered if UUID.match?(lowered) && lowered != NIL_UUID
      end

      def printable_ascii(value)
        value if PRINTABLE_ASCII.match?(value)
      end
    end
  end
end
