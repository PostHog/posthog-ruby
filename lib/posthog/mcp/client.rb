# frozen_string_literal: true

module PostHog
  module MCP
    # A {PostHog::Client} with first-class MCP analytics for custom dispatchers
    # (your own HTTP layer, no `MCP::Server` to wrap). The host resolves
    # identity and context per request and calls the capture methods directly;
    # events flow through the same sanitize -> truncate -> `$exception` fan-out
    # pipeline as {PostHog::MCP.instrument}. Does not need the `mcp` gem.
    #
    # @note Experimental.
    #
    # @example
    #   posthog = PostHog::MCP::Client.new(api_key: 'phc_...', host: 'https://us.i.posthog.com')
    #   posthog.capture_tool_call('search_docs', duration_ms: 42, distinct_id: 'user_123')
    class Client < PostHog::Client
      # @param opts [Hash] {PostHog::Client} options plus:
      # @option opts [String] :missing_capability_tool_name name of the virtual tool (default `get_more_tools`)
      # @option opts [Boolean] :mcp_exception_autocapture emit a sibling `$exception` for failed calls (default true)
      def initialize(opts = {})
        opts = opts.transform_keys(&:to_sym)
        @missing_capability_tool_name = opts.delete(:missing_capability_tool_name) || Tools::GET_MORE_TOOLS_NAME
        @mcp_exception_autocapture = opts.delete(:mcp_exception_autocapture) != false
        super
        @mcp_sink = Sink.new(self)
        @mcp_options = Options.new(
          enable_exception_autocapture: @mcp_exception_autocapture,
          missing_capability_tool_name: @missing_capability_tool_name
        )
      end

      # Capture a tool invocation. Emits `$mcp_tool_call` (+ `$exception` on error).
      #
      # @return [void]
      def capture_tool_call(tool_name, intent: nil, intent_source: nil, parameters: nil, response: nil,
                            duration_ms: nil, is_error: false, error: nil, error_type: nil, category: nil,
                            tool_description: nil, protocol_version: nil, distinct_id: nil, session_id: nil,
                            client_user_agent: nil, vendor_client: nil, set_properties: nil, groups: nil,
                            properties: nil, timestamp: nil, llm_model: nil, llm_model_source: nil)
        event = base_event(EventType::MCP_TOOLS_CALL, distinct_id, session_id, set_properties, groups, properties,
                           timestamp, client_user_agent, vendor_client)
        event['resource_name'] = tool_name
        event['tool_description'] = tool_description
        event['tool_category'] = category
        event['protocol_version'] = protocol_version
        event['parameters'] = parameters
        event['response'] = response
        event['duration'] = duration_ms
        event['is_error'] = is_error == true
        event['error_type'] = error_type
        apply_intent(event, intent, intent_source)
        model = ModelCapture.normalize(llm_model)
        if model
          event['llm_model'] = model
          event['llm_model_source'] = llm_model_source || 'self_reported'
        end
        if is_error
          event['error'] =
            Exceptions.capture_exception(error.nil? ? "Tool #{tool_name} returned an error" : error)
        end
        emit(event)
      end

      # Capture the connection handshake. Emits `$mcp_initialize`.
      #
      # @return [void]
      def capture_initialize(client_name: nil, client_version: nil, protocol_version: nil, parameters: nil,
                             response: nil, duration_ms: nil, distinct_id: nil, session_id: nil,
                             client_user_agent: nil, vendor_client: nil, set_properties: nil, groups: nil,
                             properties: nil, timestamp: nil)
        event = base_event(EventType::MCP_INITIALIZE, distinct_id, session_id, set_properties, groups, properties,
                           timestamp, client_user_agent, vendor_client)
        event['client_name'] = client_name
        event['client_version'] = client_version
        event['protocol_version'] = protocol_version
        event['parameters'] = parameters
        event['response'] = response
        event['duration'] = duration_ms
        emit(event)
      end

      # Capture a `tools/list` response. Emits `$mcp_tools_list` with `$mcp_listed_tool_names`.
      #
      # @return [void]
      def capture_tools_list(tool_names: nil, parameters: nil, response: nil, duration_ms: nil, is_error: false,
                             error: nil, error_type: nil, protocol_version: nil, distinct_id: nil, session_id: nil,
                             client_user_agent: nil, vendor_client: nil, set_properties: nil, groups: nil,
                             properties: nil, timestamp: nil)
        event = base_event(EventType::MCP_TOOLS_LIST, distinct_id, session_id, set_properties, groups, properties,
                           timestamp, client_user_agent, vendor_client)
        event['listed_tool_names'] = tool_names
        event['protocol_version'] = protocol_version
        event['parameters'] = parameters
        event['response'] = response
        event['duration'] = duration_ms
        event['is_error'] = is_error == true
        event['error_type'] = error_type
        event['error'] = Exceptions.capture_exception(error.nil? ? 'tools/list failed' : error) if is_error
        emit(event)
      end

      # Capture a `get_more_tools` call as a missing-capability report. Emits
      # `$mcp_missing_capability` with the agent's description as `$mcp_intent`.
      #
      # @return [void]
      def capture_missing_capability(context: nil, parameters: nil, protocol_version: nil, distinct_id: nil,
                                     session_id: nil, client_user_agent: nil, vendor_client: nil,
                                     set_properties: nil, groups: nil, properties: nil, timestamp: nil)
        event = base_event(EventType::MCP_MISSING_CAPABILITY, distinct_id, session_id, set_properties, groups,
                           properties, timestamp, client_user_agent, vendor_client)
        event['resource_name'] = @missing_capability_tool_name
        event['protocol_version'] = protocol_version
        event['parameters'] = parameters
        apply_intent(event, context, 'context_parameter')
        emit(event)
      end

      # Inject the `context` argument into every tool descriptor (Hash with
      # `inputSchema`) so agents state their intent, and optionally append the
      # `get_more_tools` virtual tool. Returns a new Array of new Hashes.
      #
      # @param tools [Array<Hash>] `tools/list` entries
      # @return [Array<Hash>]
      def prepare_tool_list(tools, context: true, report_missing: false)
        options = Options.new(context: context)
        prepared = tools.map do |tool|
          next tool unless options.context_enabled? && tool.is_a?(Hash)

          name = SchemaMutation.fetch(tool, :name) || 'unknown'
          next tool if name == @missing_capability_tool_name

          schema = SchemaMutation.add_context_parameter(
            SchemaMutation.fetch(tool, :inputSchema), tool_name: name, description: options.context_description
          )
          tool.merge(SchemaMutation.key_for(tool, :inputSchema) => schema)
        end
        if report_missing && prepared.none? { |t| SchemaMutation.fetch(t, :name) == @missing_capability_tool_name }
          prepared << Tools.descriptor(@missing_capability_tool_name)
        end
        prepared
      end

      # Pull the agent's intent off the injected `context` argument, strip it
      # from the arguments, and flag the `get_more_tools` virtual tool.
      #
      # @return [PreparedToolCall]
      def prepare_tool_call(name, args = nil)
        raw_context = args.is_a?(Hash) ? (args[:context] || args['context']) : nil
        intent = raw_context.is_a?(String) && !raw_context.strip.empty? ? raw_context.strip : nil
        PreparedToolCall.new(
          args: strip_context(args),
          intent: intent,
          intent_source: intent ? 'context_parameter' : nil,
          is_missing_capability: name == @missing_capability_tool_name
        )
      end

      private

      def base_event(event_type, distinct_id, session_id, set_properties, groups, properties, timestamp,
                     client_user_agent, vendor_client)
        event = {
          'event_type' => event_type,
          'session_id' => session_id,
          'timestamp' => timestamp || Time.now.utc,
          'properties' => properties,
          'groups' => groups,
          'client_user_agent' => client_user_agent,
          'vendor_client' => vendor_client
        }
        event['identify_actor_given_id'] = distinct_id if distinct_id.is_a?(String) && !distinct_id.empty?
        event['identify_actor_data'] = set_properties if set_properties.is_a?(Hash) && !set_properties.empty?
        event
      end

      def apply_intent(event, intent, source)
        trimmed = intent.is_a?(String) ? intent.strip : ''
        return if trimmed.empty?

        event['user_intent'] = trimmed
        event['user_intent_source'] = source || 'context_parameter'
      end

      def emit(event)
        @mcp_sink.capture(event, @mcp_options)
        nil
      end

      def strip_context(args)
        return args unless args.is_a?(Hash) && (args.key?(:context) || args.key?('context'))

        args.except(:context, 'context')
      end
    end
  end
end
