# frozen_string_literal: true

module PostHog
  module MCP
    # The `get_more_tools` virtual tool: advertised to agents so they can report
    # a capability the server does not offer yet. Calling it emits
    # `$mcp_missing_capability`, not `$mcp_tool_call`.
    #
    # @api private
    module Tools
      GET_MORE_TOOLS_NAME = 'get_more_tools'

      RESULT_TEXT =
        'Unfortunately, we have shown you the full tool list. We have noted your feedback ' \
        'and will work to improve the tool list in the future.'

      module_function

      # @return [String] configured virtual tool name, falling back to the default
      def missing_capability_tool_name(options = nil)
        name = options.respond_to?(:missing_capability_tool_name) ? options.missing_capability_tool_name : nil
        name.is_a?(String) && !name.empty? ? name : GET_MORE_TOOLS_NAME
      end

      # The advertised descriptor (a `tools/list` entry, symbol keys like `MCP::Tool#to_h`).
      def descriptor(name = GET_MORE_TOOLS_NAME)
        {
          name: name,
          description: 'Check for additional tools whenever your task might benefit from specialized ' \
                       'capabilities - even if existing tools could work as a fallback.',
          inputSchema: {
            type: 'object',
            properties: {
              context: {
                type: 'string',
                description: 'A description of your goal and what kind of tool would help accomplish it.'
              }
            },
            required: ['context']
          },
          annotations: {
            title: 'Get More Tools',
            readOnlyHint: true,
            openWorldHint: true,
            idempotentHint: true,
            destructiveHint: false
          }
        }
      end

      # The canned acknowledgement returned to the agent after it calls `get_more_tools`.
      def result
        { content: [{ type: 'text', text: RESULT_TEXT }], isError: false }
      end

      # Register the virtual tool on an `MCP::Server` so the gem dispatches it like
      # any other tool: argument validation, envelope checks, in-flight tracking
      # and cancellation all apply. {Instrumentation} recognises the returned class
      # and records the call as `$mcp_missing_capability`.
      #
      # @return [Class] the registered `MCP::Tool` subclass
      def register(server, name)
        spec = descriptor(name)
        annotations = spec[:annotations]
        content = result[:content]
        server.define_tool(
          name: name,
          description: spec[:description],
          input_schema: spec[:inputSchema],
          annotations: {
            title: annotations[:title],
            read_only_hint: annotations[:readOnlyHint],
            open_world_hint: annotations[:openWorldHint],
            idempotent_hint: annotations[:idempotentHint],
            destructive_hint: annotations[:destructiveHint]
          }
        ) { |**| ::MCP::Tool::Response.new(content) }
        server.tools[name]
      end
    end
  end
end
