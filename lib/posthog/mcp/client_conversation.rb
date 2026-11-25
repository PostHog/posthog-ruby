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
      # `id` returns the id when a value is the row's shape. `handle_free`: the
      # client sends its id on every call, so it is advertised no
      # `conversation_id` and minted no handle.
      Row = Struct.new(:key, :id, :user_agent, :client_names, :handle_free, keyword_init: true) do
        def recognizes?(user_agent, client_name)
          return true if user_agent.is_a?(String) && self.user_agent.match?(user_agent)

          client_name.is_a?(String) && client_names.any? { |name| name.casecmp?(client_name) }
        end
      end

      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
      NIL_UUID = '00000000-0000-0000-0000-000000000000'
      PRINTABLE_ASCII = /\A[\x20-\x7e]{1,128}\z/

      uuid = lambda do |value|
        lowered = value.downcase
        lowered if UUID.match?(lowered) && lowered != NIL_UUID
      end

      ROWS = [
        Row.new(key: 'openai/session', id: ->(value) { value if PRINTABLE_ASCII.match?(value) }, handle_free: true,
                user_agent: %r{\Aopenai-mcp/[^\s(]*\s*\(\s*chatgpt\s*[;,)]}i, client_names: []),
        Row.new(key: 'sessionId', id: uuid, handle_free: false,
                user_agent: %r{\Acodex-mcp-client/}i, client_names: ['codex-mcp-client']),
        Row.new(key: 'vscode.conversationId', id: uuid, handle_free: false,
                user_agent: %r{\AVisual Studio Code(?: - Insiders)?/}i,
                client_names: ['Visual Studio Code', 'Visual Studio Code - Insiders'])
      ].freeze

      module_function

      # @return [Row, nil] the first row that recognizes the request
      def recognize(user_agent, client_name)
        ROWS.find { |row| row.recognizes?(user_agent, client_name) }
      end

      # @return [String, nil] `"<key>:<id>"`, what the session is derived from
      def read(row, meta)
        value = row && SchemaMutation.fetch(meta, row.key)
        id = row.id.call(value) if value.is_a?(String)
        id && "#{row.key}:#{id}"
      end
    end
  end
end
