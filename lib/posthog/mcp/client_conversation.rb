# frozen_string_literal: true

module PostHog
  module MCP
    # {ROWS} is the table of the MCP analytics spec's "Session identity"
    # requirement, row for row, in its order. posthog-js and posthog-python keep
    # the same table.
    #
    # @api private
    module ClientConversation
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

      def recognize(user_agent, client_name)
        ROWS.find { |row| row.recognizes?(user_agent, client_name) }
      end

      def read(row, meta)
        value = row && SchemaMutation.fetch(meta, row.key)
        id = row.id.call(value) if value.is_a?(String) && value.valid_encoding?
        id && "#{row.key}:#{id}"
      end
    end
  end
end
