# frozen_string_literal: true

require 'json'

module PostHog
  module MCP
    # Optional `conversation_id` loop-back. When enabled, the SDK injects a
    # `conversation_id` parameter into every tool, mints one when the agent does
    # not supply it, hands it back on the response, and captures it as
    # `$mcp_conversation_id`, stitching calls across reconnects and pods.
    #
    # @api private
    module ConversationId
      PARAM_NAME = 'conversation_id'
      MINTED_CONVERSATION_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

      MCP_INSTRUCTIONS_KEY = '_mcp_instructions'
      INSTRUCTIONS_FIELD_DESCRIPTION = 'Server-issued metadata for this conversation.'
      CONVERSATION_ID_FIELD_DESCRIPTION = 'The server-issued conversation identifier.'

      module_function

      def extract(args)
        return nil unless args.is_a?(Hash)

        value = args[PARAM_NAME] || args[PARAM_NAME.to_sym]
        return nil unless value.is_a?(String)

        trimmed = value.strip
        trimmed.empty? ? nil : trimmed
      end

      # @return [Array(String, Boolean), Array(nil, false)] `[conversation_id, minted]`
      def resolve(enabled, args, tool_name, missing_capability_tool_name)
        return [nil, false] if !enabled || tool_name == missing_capability_tool_name

        supplied = extract(args)
        return [supplied.downcase, false] if supplied && MINTED_CONVERSATION_ID.match?(supplied)

        [Ids.uuid_v7, true]
      end

      def prompt_back?(result)
        result.is_a?(Hash) && (result[:content] || result['content']).is_a?(Array)
      end

      # Plain data, not an instruction: an instruction-shaped block is what a
      # client's prompt-injection filter strips. Compact JSON.
      def build_prompt_back(conversation_id)
        { type: 'text', text: JSON.generate({ conversation_id: conversation_id }) }
      end

      # @return [Hash] a new result with the prompt-back appended (or the input unchanged)
      def inject_prompt_back(result, conversation_id)
        return result unless prompt_back?(result)

        key = result.key?(:content) ? :content : 'content'
        result.merge(key => result[key] + [build_prompt_back(conversation_id)])
      end

      # Mirror the handle into `structuredContent` for tools whose output schema
      # declared `_mcp_instructions`. Customer data wins when the key exists.
      #
      # @return [Array(Object, Boolean)] `[result, delivered]`
      def mirror_instructions(result, conversation_id)
        return [result, false] unless result.is_a?(Hash)

        key = %i[structuredContent structured_content].find { |k| result.key?(k) } ||
              %w[structuredContent structured_content].find { |k| result.key?(k) }
        return [result, false] if key.nil?

        structured = result[key]
        return [result, false] unless structured.is_a?(Hash)
        return [result, false] if structured.key?(MCP_INSTRUCTIONS_KEY) || structured.key?(MCP_INSTRUCTIONS_KEY.to_sym)

        payload = { 'conversation_id' => conversation_id }
        instructions_key = structured.keys.first.is_a?(Symbol) ? MCP_INSTRUCTIONS_KEY.to_sym : MCP_INSTRUCTIONS_KEY
        [result.merge(key => structured.merge(instructions_key => payload)), true]
      end
    end
  end
end
