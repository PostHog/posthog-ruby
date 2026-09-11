# frozen_string_literal: true

module PostHog
  module MCP
    # One JSON-RPC request's analytics lifecycle. Created by {ServerExtension}
    # around the dispatch lambda `MCP::Server#handle_request` returns, so it
    # sees the raw request, the params Hash the handler will receive (and may
    # strip injected arguments from it), the session, the result, and any
    # raised error. Everything it needs travels through its own instance
    # variables; nothing is read from the gem's `@instrumentation_data`.
    #
    # Analytics failures are logged and swallowed: the handler's result or
    # exception is always returned or re-raised unchanged.
    #
    # @api private
    class Instrumentation
      TRACKED_METHODS = {
        'initialize' => :initialize,
        'tools/list' => :tools_list,
        'tools/call' => :tools_call,
        'prompts/get' => :prompts_get,
        'prompts/list' => :prompts_list,
        'resources/read' => :resources_read,
        'resources/list' => :resources_list
      }.freeze

      GENERIC_EVENT_TYPES = {
        prompts_get: EventType::MCP_PROMPTS_GET,
        prompts_list: EventType::MCP_PROMPTS_LIST,
        resources_read: EventType::MCP_RESOURCES_READ,
        resources_list: EventType::MCP_RESOURCES_LIST
      }.freeze

      MODERN_PROTOCOL_REVISION = '2026-07-28'
      REVISION_SHAPE = /\A\d{4}-\d{2}-\d{2}\z/
      DRAFT_REVISION = 'draft'
      META_CLIENT_INFO_KEY = 'io.modelcontextprotocol/clientInfo'
      META_PROTOCOL_VERSION_KEY = 'io.modelcontextprotocol/protocolVersion'
      INJECTED_PARAMS = ['context', ConversationId::PARAM_NAME, ModelCapture::PARAM_NAME].freeze

      class << self
        def tracked?(method)
          TRACKED_METHODS.key?(method)
        end

        # Enrich an event with session/identity/server metadata and hand it to
        # the sink.
        def capture_event(data, input)
          sink = data.sink
          return nil if sink.nil?

          session_id = input['session_id'] || data.session_id
          actor = session_id ? data.identified_sessions.get(session_id) : nil
          timestamp = input['timestamp'] || Time.now.utc
          duration = input['duration']
          duration = (Time.now - timestamp) * 1000.0 if duration.nil? && input['timestamp']

          full = input.merge(
            'session_id' => session_id,
            'event_type' => input['event_type'] || EventType::CUSTOM,
            'timestamp' => timestamp,
            'duration' => duration,
            'server_name' => data.server_name,
            'server_version' => data.server_version,
            'identify_actor_given_id' => actor&.distinct_id,
            'identify_actor_data' => actor ? (actor.properties || {}) : {},
            'groups' => actor&.groups
          )
          sink.capture(full, data.options)
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def legacy_era?(protocol_version)
          return true unless protocol_version.is_a?(String) && !protocol_version.empty?
          return false if protocol_version == DRAFT_REVISION

          !(REVISION_SHAPE.match?(protocol_version) && protocol_version >= MODERN_PROTOCOL_REVISION)
        end
      end

      def initialize(server, data, method:, request:, params:, session: nil, request_id: nil)
        @server = server
        @data = data
        @options = data.options
        @kind = TRACKED_METHODS.fetch(method)
        @method = method
        @request = request.is_a?(Hash) ? request : {}
        @params = params.is_a?(Hash) ? params : {}
        @session = session
        @request_id = request_id
        @scope = RequestScope.current
        @headers = @scope ? (@scope[:headers] || {}) : {}
        @token = SessionToken.decode(header_session_id)
        @data.http_transport_seen = true if http?
        @identified_in_request = {}
      end

      # Runs the wrapped handler and records the request.
      def dispatch(&handler)
        @start = self.class.monotonic_now
        return dispatch_kind(&handler) if @scope

        # Only the Streamable HTTP transport publishes a scope. Opening one for
        # every other transport too (stdio, a custom dispatcher) means the session
        # settled before the tool body runs is the one {Analytics#capture} reads
        # inside it, whatever the request is anchored on.
        RequestScope.with(headers: {}, transport: :other) do |scope|
          @scope = scope
          dispatch_kind(&handler)
        end
      end

      private

      def dispatch_kind(&handler)
        case @kind
        when :tools_call then dispatch_tool_call(&handler)
        when :tools_list then dispatch_tools_list(&handler)
        when :initialize then dispatch_initialize(&handler)
        else dispatch_generic(&handler)
        end
      end

      # --- dispatchers -------------------------------------------------------

      def dispatch_tool_call
        name = fetch(@params, :name)
        arguments = fetch(@params, :arguments)
        arguments = nil unless arguments.is_a?(Hash)
        original_arguments = arguments&.dup
        missing_name = Tools.missing_capability_tool_name(@options)
        owned = safely([]) { owned_params_for(name) }
        stripped = safely({}) { strip_injected_arguments(arguments, owned) }
        conversation_id, minted = safely([nil, false]) do
          ConversationId.resolve(@options.enable_conversation_id, original_arguments, name, missing_name)
        end
        request = request_with_arguments(original_arguments)

        if virtual_tool?(name)
          # Run the gem's own handler so validation, in-flight tracking and
          # cancellation behave exactly as for any other tool; only the event differs.
          begin
            result = yield
          ensure
            safely { record_missing_capability(name, original_arguments, request) }
          end
          return result
        end

        safely { prime_session(request, minted ? nil : conversation_id) }
        begin
          result = yield
        rescue StandardError => e
          safely do
            cid = minted ? nil : conversation_id
            session_id = prepare_request(request, conversation_id: cid)
            record_tool_call(session_id, name, request, error: e, conversation_id: cid, stripped: stripped)
          end
          raise
        end

        delivered = false
        # The handle appended below is unique per conversation, so an error read
        # off the delivered result would give every identical failure a different
        # `$mcp_error_message`. Grouping reads the result the tool returned.
        error_source = result
        unless no_response?(result) || conversation_id.nil?
          safely do
            if @data.tool_output_instructions[name]
              result, delivered = ConversationId.mirror_instructions(result, conversation_id)
            end
            if minted
              with_prompt_back = ConversationId.inject_prompt_back(result, conversation_id)
              delivered ||= !with_prompt_back.equal?(result)
              result = with_prompt_back
            end
          end
        end

        safely do
          cid = minted && !delivered ? nil : conversation_id
          session_id = prepare_request(request, conversation_id: cid)
          record_tool_call(session_id, name, request, result: result, conversation_id: cid,
                                                      stripped: stripped, error_source: error_source)
        end
        result
      end

      def dispatch_tools_list
        result = begin
          yield
        rescue StandardError => e
          safely { record_tools_list(prepare_request(@request), names: [], error: e) }
          raise
        end

        return result if no_response?(result)

        names = []
        empty = false
        safely do
          tools = fetch(result, :tools)
          if tools.is_a?(Array)
            names = tools.map { |tool| fetch(tool, :name) }.compact
            empty = tools.empty?
            mutated = tools.map { |tool| mutate_tool(tool) }
            result = result.merge(SchemaMutation.key_for(result, :tools) => mutated)
          end
        end

        safely do
          session_id = prepare_request(@request)
          record_tools_list(session_id, names: names, response: result, empty: empty)
        end
        result
      end

      def dispatch_initialize
        client_info = fetch(@params, :clientInfo)
        client_name = client_info.is_a?(Hash) ? fetch(client_info, :name) : nil
        client_version = client_info.is_a?(Hash) ? fetch(client_info, :version) : nil
        requested_version = fetch(@params, :protocolVersion)

        result = begin
          yield
        rescue StandardError => e
          safely do
            session_id = prepare_request(@request, skip_initialize: true)
            record_initialize(session_id, client_name, client_version, requested_version, error: e)
          end
          raise
        end

        safely do
          negotiated = (result.is_a?(Hash) ? fetch(result, :protocolVersion) : nil) || requested_version
          minted = mint_session_token(client_name, client_version, negotiated, requested_version)
          session_id = prepare_request(@request, skip_initialize: true, token: minted)
          record_initialize(session_id, client_name, client_version, negotiated, response: result)
        end
        result
      end

      def dispatch_generic
        result = begin
          yield
        rescue StandardError => e
          safely { record_generic(prepare_request(@request), error: e) }
          raise
        end
        safely { record_generic(prepare_request(@request), result: result) }
        result
      end

      # --- recording ---------------------------------------------------------

      def record_tool_call(session_id, name, request, result: nil, error: nil, conversation_id: nil, stripped: {},
                           error_source: nil)
        event = base_event(EventType::MCP_TOOLS_CALL, session_id, request)
        event['resource_name'] = name
        event['tool_description'] = @data.tool_descriptions[name]
        event['tool_category'] = @data.tool_categories[name]
        event['parameters'] = Sanitization.build_captured_mcp_parameters(request)
        event['conversation_id'] = conversation_id
        event['is_error'] = false

        intent = Intent.resolve(@data, request, extra)
        if intent
          event['user_intent'] = intent[0]
          event['user_intent_source'] = intent[1]
        end
        if @options.capture_model_enabled?
          model = ModelCapture.resolve(request, stripped[ModelCapture::PARAM_NAME])
          if model
            event['llm_model'] = model[0]
            event['llm_model_source'] = model[1]
          end
        end

        if error
          event['is_error'] = true
          event['error'] = Exceptions.capture_exception(error)
        elsif !result.nil? && !no_response?(result)
          event['response'] = result
          source = error_source.nil? ? result : error_source
          if tool_result_error?(source)
            event['is_error'] = true
            event['error'] = Exceptions.capture_exception(Sanitization.stringify_keys(source))
          end
        end

        finish_event(event, request)
      end

      def record_missing_capability(name, arguments, request)
        session_id = prepare_request(request)
        event = base_event(EventType::MCP_MISSING_CAPABILITY, session_id, request)
        event.delete('duration')
        event['resource_name'] = name
        event['parameters'] = Sanitization.build_captured_mcp_parameters(request)
        context = arguments.is_a?(Hash) ? (arguments[:context] || arguments['context']) : nil
        if context.is_a?(String) && !context.strip.empty?
          event['user_intent'] = context.strip
          event['user_intent_source'] = 'context_parameter'
        end
        if @options.capture_model_enabled?
          model = ModelCapture.resolve(request, self_reported_model(arguments))
          if model
            event['llm_model'] = model[0]
            event['llm_model_source'] = model[1]
          end
        end
        finish_event(event, request)
      end

      # The virtual tool declares `llm_model` itself, so the argument is never
      # stripped and is read straight off the call.
      def self_reported_model(arguments)
        return nil unless arguments.is_a?(Hash)

        arguments[ModelCapture::PARAM_NAME] || arguments[ModelCapture::PARAM_NAME.to_sym]
      end

      def record_tools_list(session_id, names:, response: nil, empty: false, error: nil)
        event = base_event(EventType::MCP_TOOLS_LIST, session_id, @request)
        event['listed_tool_names'] = names
        event['parameters'] = Sanitization.build_captured_mcp_parameters(@request)
        event['response'] = response unless response.nil? || no_response?(response)
        event['is_error'] = !error.nil? || empty
        event['timestamp'] = Time.now.utc
        if error
          event['error'] = Exceptions.capture_exception(error)
        elsif empty
          event['error'] = Exceptions.capture_exception('tools/list returned no tools')
        end
        finish_event(event, @request)
      end

      def record_initialize(session_id, client_name, client_version, protocol_version, response: nil, error: nil)
        @data.mark_session_initialized(session_id)
        event = base_event(EventType::MCP_INITIALIZE, session_id, @request)
        event['client_name'] = client_name
        event['client_version'] = client_version
        event['protocol_version'] = protocol_version
        event['parameters'] = Sanitization.build_captured_mcp_parameters(@request)
        event['response'] = response unless response.nil? || no_response?(response)
        if error
          event['is_error'] = true
          event['error'] = Exceptions.capture_exception(error)
        end
        finish_event(event, @request)
      end

      def record_generic(session_id, result: nil, error: nil)
        event = base_event(GENERIC_EVENT_TYPES.fetch(@kind), session_id, @request)
        event['resource_name'] = generic_resource_name
        event['parameters'] = Sanitization.build_captured_mcp_parameters(@request)
        event['response'] = result unless result.nil? || no_response?(result)
        event['is_error'] = !error.nil?
        event['error'] = Exceptions.capture_exception(error) if error
        finish_event(event, @request)
      end

      def base_event(event_type, session_id, request)
        event = {
          'event_type' => event_type,
          'session_id' => session_id,
          'duration' => duration_ms,
          'client_name' => nil,
          'client_version' => nil,
          'protocol_version' => protocol_version
        }
        name, version = client_identity(request)
        event['client_name'] = name
        event['client_version'] = version
        event
      end

      def finish_event(event, request)
        props = resolve_event_properties(request)
        event['properties'] = props unless props.nil?
        TransportIdentity.stamp(event, @headers)
        self.class.capture_event(@data, event)
      end

      def resolve_event_properties(request)
        callback = @options.event_properties
        return nil unless callback

        result = Callbacks.call(callback, request, extra)
        result.is_a?(Hash) && !result.empty? ? result : nil
      rescue StandardError => e
        Log.debug(@options, "event_properties callback error: #{e.message}")
        nil
      end

      # --- session / identity -----------------------------------------------

      # Settle session and identity before the tool body runs, and pin the session
      # to the request scope. {Analytics#capture} reads both from there, so a
      # custom event emitted inside a tool belongs to its caller rather than to
      # whichever request finished last (or is running concurrently), and carries
      # the same identified person as the `$mcp_tool_call` that follows it.
      #
      # `conversation_id` is passed when the agent echoed one back: that anchor is
      # already known, so priming resolves the same session the tool call will be
      # recorded under. A minted handle is not known to have reached the agent
      # until the call returns, so it stays out of here. {#prepare_request} runs
      # again after the call; the second run is idempotent.
      def prime_session(request, conversation_id)
        session_id = prepare_request(request, conversation_id: conversation_id)
        @scope[:session_id] = session_id if @scope.is_a?(Hash)
      end

      # Resolve the session id, run identify, then lazily emit initialize.
      def prepare_request(request, conversation_id: nil, skip_initialize: false, token: nil)
        token ||= @token
        session_id, source = Session.resolve(@data, mcp_session_id(token), token: token,
                                                                           conversation_id: conversation_id)
        warn_stateless_session_not_wired if source == 'generated' && http?

        # A tool call prepares twice: once before the body to pin the session, and
        # once after it, when the conversation anchor is known. A customer's
        # `identify` callback runs once per session per request, so preparing
        # twice never asks it the same question twice.
        unless @identified_in_request.key?(session_id)
          @identified_in_request[session_id] = true
          identify_event = Identity.handle_identify(@data, session_id, request, extra)
          self.class.capture_event(@data, identify_event) if identify_event
        end
        maybe_emit_initialize(session_id, request) unless skip_initialize
        session_id
      end

      def maybe_emit_initialize(session_id, request)
        return if @data.session_initialized?(session_id)

        @data.mark_session_initialized(session_id)
        name, version = client_identity(request)
        event = {
          'event_type' => EventType::MCP_INITIALIZE,
          'session_id' => session_id,
          'client_name' => name,
          'client_version' => version,
          'protocol_version' => protocol_version,
          'timestamp' => Time.now.utc
        }
        props = resolve_event_properties({ method: 'initialize', params: {} })
        event['properties'] = props unless props.nil?
        TransportIdentity.stamp(event, @headers)
        self.class.capture_event(@data, event)
      end

      # Era is decided by the version the client *asked for*:
      # a client declaring the 2026-07-28 revision or later must not be answered
      # with an `Mcp-Session-Id`, even though this gem counter-offers a legacy version.
      def mint_session_token(client_name, client_version, protocol_version, requested_version)
        return nil unless http? && @scope
        return nil if header_session_id || @session&.session_id
        return nil unless self.class.legacy_era?(requested_version)

        payload = SessionTokenPayload.new(
          session_id: Session.new_session_id,
          client_name: client_name.is_a?(String) ? client_name : nil,
          client_version: client_version.is_a?(String) ? client_version : nil,
          protocol_version: protocol_version.is_a?(String) ? protocol_version : nil
        )
        @scope[:mint] = SessionToken.encode(payload)
        payload
      end

      def warn_stateless_session_not_wired
        return if @data.warned_no_stateless_session

        @data.warned_no_stateless_session = true
        Log.warn(
          @options,
          'Warning: an MCP request arrived over streamable HTTP with no session id, so PostHog generated a ' \
          'per-process $session_id that will fragment across requests and pods. In stateless mode the ' \
          'client must replay the Mcp-Session-Id header PostHog::MCP mints at initialize; for a custom Rack ' \
          'stack add PostHog::MCP::RackMiddleware. Enabling conversation ids ' \
          '(PostHog::MCP.instrument(server, enable_conversation_id: true)) also anchors the session without ' \
          'any middleware. See lib/posthog/mcp/README.md (stateless / multi-pod servers).'
        )
      end

      # --- request context ---------------------------------------------------

      def header_session_id
        SessionToken.read_header(@headers)
      end

      # The transport's own session id (never our token).
      def mcp_session_id(token)
        transport_id = @session.respond_to?(:session_id) ? @session.session_id : nil
        return transport_id if transport_id.is_a?(String) && !transport_id.empty?

        token ? nil : header_session_id
      end

      def http?
        @scope.is_a?(Hash) && @scope[:transport] == :http
      end

      def envelope_meta
        meta = fetch(@params, :_meta)
        meta.is_a?(Hash) ? meta : nil
      end

      def client_identity(request)
        info = envelope_client_info || session_client || server_client
        info = fetch(request_params(request), :clientInfo) if info.nil? && @kind == :initialize
        name = info.is_a?(Hash) ? fetch(info, :name) : nil
        version = info.is_a?(Hash) ? fetch(info, :version) : nil
        name ||= @token&.client_name
        version ||= @token&.client_version
        [name, version]
      end

      def envelope_client_info
        meta = envelope_meta
        return nil unless meta

        meta[META_CLIENT_INFO_KEY] || meta[META_CLIENT_INFO_KEY.to_sym]
      end

      def session_client
        @session.respond_to?(:client) ? @session.client : nil
      end

      def server_client
        @server.instance_variable_defined?(:@client) ? @server.instance_variable_get(:@client) : nil
      end

      def protocol_version
        meta = envelope_meta
        from_meta = meta ? (meta[META_PROTOCOL_VERSION_KEY] || meta[META_PROTOCOL_VERSION_KEY.to_sym]) : nil
        return from_meta if from_meta.is_a?(String)

        from_session = @session.respond_to?(:protocol_version) ? @session.protocol_version : nil
        return from_session if from_session.is_a?(String)

        if @server.instance_variable_defined?(:@client_protocol_version)
          from_server = @server.instance_variable_get(:@client_protocol_version)
          return from_server if from_server.is_a?(String)
        end

        @headers['mcp-protocol-version'] || @token&.protocol_version
      end

      def extra
        @extra ||= {
          'session_id' => (@session.respond_to?(:session_id) ? @session.session_id : nil) || header_session_id,
          'request_id' => @request_id,
          'protocol_version' => protocol_version,
          'headers' => @headers,
          'session' => @session
        }
      end

      def request_params(request)
        params = request.is_a?(Hash) ? (request[:params] || request['params']) : nil
        params.is_a?(Hash) ? params : {}
      end

      def request_with_arguments(arguments)
        params = @params.merge(SchemaMutation.key_for(@params, :arguments) => arguments)
        @request.merge(SchemaMutation.key_for(@request, :params) => params)
      end

      def generic_resource_name
        case @kind
        when :prompts_get then fetch(@params, :name)
        when :resources_read then fetch(@params, :uri)
        end
      end

      def duration_ms
        (self.class.monotonic_now - @start) * 1000.0
      end

      # --- tools -------------------------------------------------------------

      # True only for the `get_more_tools` class {Tools.register} added; an
      # application tool that shares the name is an ordinary tool.
      def virtual_tool?(name)
        return false if @data.virtual_tool.nil?

        tools = @server.respond_to?(:tools) ? @server.tools : nil
        tools.is_a?(Hash) && tools[name].equal?(@data.virtual_tool)
      end

      # Injected argument names the analytics layer owns for this tool: the ones
      # it injected at tools/list, or (never listed) the ones the tool's own
      # schema does not declare. A composed or referenced schema is never
      # injected into, so nothing in it is ours to strip either - the same guard
      # {SchemaMutation.add_parameter} uses, so a call before the first
      # tools/list behaves exactly like one after it.
      def owned_params_for(name)
        cached = @data.tool_owned_params[name]
        return cached if cached

        tools = @server.respond_to?(:tools) ? @server.tools : nil
        tool = tools.is_a?(Hash) ? tools[name] : nil
        schema = tool.respond_to?(:input_schema) ? tool.input_schema&.to_h : nil
        return [] unless SchemaMutation.injectable?(schema)

        owned = []
        owned << 'context' if @options.context_enabled? && !SchemaMutation.declares_param?(schema, 'context')
        owned << ConversationId::PARAM_NAME if @options.enable_conversation_id &&
                                               !SchemaMutation.declares_param?(schema, ConversationId::PARAM_NAME)
        owned << ModelCapture::PARAM_NAME if @options.capture_model_enabled? &&
                                             !SchemaMutation.declares_param?(schema, ModelCapture::PARAM_NAME)
        owned
      end

      # Remove SDK-owned arguments in place before the tool receives them as
      # keywords (an unknown keyword would raise). Returns the stripped values.
      def strip_injected_arguments(arguments, owned)
        stripped = {}
        return stripped unless arguments.is_a?(Hash)

        owned.each do |param|
          [param.to_sym, param].each do |key|
            next unless arguments.key?(key)

            value = arguments.delete(key)
            stripped[param] = value if stripped[param].nil?
          end
        end
        stripped
      end

      def mutate_tool(tool)
        return tool unless tool.is_a?(Hash)

        name = fetch(tool, :name)
        return tool if virtual_tool?(name)

        schema = fetch(tool, :inputSchema)
        owned = []
        if @options.context_enabled?
          updated = SchemaMutation.add_context_parameter(
            schema, tool_name: name, description: @options.context_description, options: @options
          )
          owned << 'context' unless updated.equal?(schema)
          schema = updated
        end
        if @options.enable_conversation_id
          updated = SchemaMutation.add_conversation_id_parameter(schema, tool_name: name, options: @options)
          owned << ConversationId::PARAM_NAME unless updated.equal?(schema)
          schema = updated
        end
        if @options.capture_model_enabled?
          updated = SchemaMutation.add_model_parameter(
            schema, tool_name: name, description: @options.model_description, options: @options
          )
          owned << ModelCapture::PARAM_NAME unless updated.equal?(schema)
          schema = updated
        end

        mutated = tool.merge(SchemaMutation.key_for(tool, :inputSchema) => schema)
        declared = nil
        if @options.enable_conversation_id
          output_schema = fetch(tool, :outputSchema)
          new_output, declared = SchemaMutation.add_output_instructions(output_schema, tool_name: name,
                                                                                       options: @options)
          mutated = mutated.merge(SchemaMutation.key_for(tool, :outputSchema) => new_output) if declared && new_output
        end

        meta = fetch(tool, :_meta)
        category = meta.is_a?(Hash) ? (meta[:category] || meta['category']) : nil
        @data.remember_tool(name, description: fetch(tool, :description), category: category, owned_params: owned,
                                  output_instructions: declared)
        mutated
      end

      # --- helpers -----------------------------------------------------------

      def fetch(hash, key)
        SchemaMutation.fetch(hash, key)
      end

      def tool_result_error?(result)
        result.is_a?(Hash) && (result[:isError] == true || result['isError'] == true)
      end

      def no_response?(result)
        defined?(::JsonRpcHandler::NO_RESPONSE) && result.equal?(::JsonRpcHandler::NO_RESPONSE)
      end

      def safely(fallback = nil)
        yield
      rescue StandardError => e
        Log.debug(@options,
                  "PostHog MCP analytics step failed (event dropped, request unaffected): #{e.class}: #{e.message}")
        fallback
      end
    end
  end
end
