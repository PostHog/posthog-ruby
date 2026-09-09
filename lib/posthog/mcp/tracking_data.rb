# frozen_string_literal: true

module PostHog
  module MCP
    # All per-server analytics state. Lives on the instrumented `MCP::Server`
    # instance (never in module-level storage), guarded by its own mutex.
    #
    # @api private
    class TrackingData
      MAX_INITIALIZED_SESSIONS = 1000

      attr_reader :options, :sink, :server_name, :server_version, :identified_sessions,
                  :tool_descriptions, :tool_categories, :tool_output_instructions, :tool_owned_params
      attr_accessor :session_id, :session_source, :last_mcp_session_id, :last_activity, :warned_no_stateless_session,
                    :virtual_tool

      def initialize(options:, sink:, server_name: nil, server_version: nil)
        @options = options
        @sink = sink
        @server_name = server_name
        @server_version = server_version
        @mutex = Mutex.new
        @session_id = nil
        @session_source = 'generated'
        @last_mcp_session_id = nil
        @last_activity = Time.now
        @warned_no_stateless_session = false
        # The `get_more_tools` class {Tools.register} added to the server, if any.
        @virtual_tool = nil
        @identified_sessions = IdentityCache.new
        @tool_descriptions = {}
        @tool_categories = {}
        # Which tools got `_mcp_instructions` declared at tools/list. Only those
        # may be mirrored into; absent fails closed.
        @tool_output_instructions = {}
        # Which injected argument names the analytics layer owns per tool (i.e.
        # the tool does not declare them itself).
        @tool_owned_params = {}
        @initialized_sessions = {}
      end

      def synchronize(&block)
        if @mutex.owned?
          yield
        else
          @mutex.synchronize(&block)
        end
      end

      def mark_session_initialized(session_id)
        synchronize do
          @initialized_sessions.delete(session_id)
          @initialized_sessions[session_id] = true
          @initialized_sessions.shift while @initialized_sessions.length > MAX_INITIALIZED_SESSIONS
        end
      end

      def session_initialized?(session_id)
        synchronize { @initialized_sessions.key?(session_id) }
      end

      def remember_tool(name, description: nil, category: nil, owned_params: nil, output_instructions: nil)
        synchronize do
          @tool_descriptions[name] = description if description.is_a?(String) && !description.empty?
          @tool_categories[name] = category if category.is_a?(String) && !category.empty?
          @tool_owned_params[name] = owned_params unless owned_params.nil?
          @tool_output_instructions[name] = output_instructions unless output_instructions.nil?
        end
      end
    end
  end
end
