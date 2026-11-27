# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require_relative 'spec_helper'
require 'rack'
require 'stringio'

class PostHogMcpSearchDocsTool < MCP::Tool
  tool_name 'search_docs'
  input_schema(properties: { query: { type: 'string' } })
  class << self
    attr_accessor :analytics, :received, :before_capture

    def call(**arguments)
      self.received = arguments.except(:server_context)
      before_capture&.call
      analytics&.capture('docs_searched')
      MCP::Tool::Response.new([{ type: 'text', text: 'found' }])
    end
  end
end

module PostHogMcpClientSessionVectors
  CHATGPT = 'openai-mcp/1.0.0 (ChatGPT)'
  CODEX = 'codex-mcp-client/0.50.0'
  CHATGPT_SESSION = 'ses_2f5d35b7108d17c807766f2f769a1e8c'
  CODEX_SESSION = 'ses_0fdf126b8e2c1f9689ca12f3dd3383e6'
  HANDLE_BLOCK = /\A\{"conversation_id":"[0-9a-f-]{36}"\}\z/

  RSpec.describe 'PostHog::MCP session identity' do
    let(:client) { new_test_client }
    let(:server) { MCP::Server.new(name: 'docs-server', version: '1.0.0', tools: [PostHogMcpSearchDocsTool]) }
    let(:transport) { MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true, enable_json_response: true) }

    before do
      allow(Kernel).to receive(:warn)
      PostHogMcpSearchDocsTool.analytics = nil
      PostHogMcpSearchDocsTool.before_capture = nil
    end

    def instrument(**options)
      PostHogMcpSearchDocsTool.analytics = PostHog::MCP.instrument(server, client, **options)
    end

    def call_search(user_agent: nil, meta: nil, arguments: { query: 'flags' }, headers: {}, id: 2)
      params = { name: 'search_docs', arguments: arguments }
      params[:_meta] = meta if meta
      headers = headers.merge('user-agent' => user_agent) if user_agent
      response = transport.call(env_for(rpc(id, 'tools/call', params), headers))
      body = parse(response)
      raise body.inspect unless body['result']

      body['result']['content'].map { |block| block['text'] }
    end

    def list_tools(user_agent)
      response = transport.call(env_for(rpc(9, 'tools/list'), 'user-agent' => user_agent))
      parse(response)['result']['tools'].to_h { |tool| [tool['name'], tool['inputSchema']['properties'].keys] }
    end

    def tool_calls
      events_named(drain_events(client), '$mcp_tool_call').map { |event| event[:properties] }
    end

    it 'derives the session from a client conversation id and adds no conversation_id block' do
      instrument
      texts = call_search(user_agent: CHATGPT, meta: { 'openai/session' => 'v1/conv-example-0001' })

      expect(texts).to eq(['found'])
      call = tool_calls.first
      expect(call['$session_id']).to eq(CHATGPT_SESSION)
      expect(call).not_to have_key('$mcp_conversation_id')
      expect(call['$mcp_session_source']).to eq('client_metadata')
    end

    it 'prefers a client conversation id to an echoed handle and strips the handle' do
      instrument
      call_search(user_agent: CHATGPT, meta: { 'openai/session' => 'v1/conv-example-0001' },
                  arguments: { query: 'flags', conversation_id: '0190f0e8-7a6b-7c3d-9e4f-5a6b7c8d9e0f' })

      expect(PostHogMcpSearchDocsTool.received).to eq(query: 'flags')
      call = tool_calls.first
      expect(call['$session_id']).to eq(CHATGPT_SESSION)
      expect(call).not_to have_key('$mcp_conversation_id')
    end

    it 'reads a client conversation id with conversation anchoring disabled' do
      instrument(enable_conversation_id: false)
      call_search(user_agent: CHATGPT, meta: { 'openai/session' => 'v1/conv-example-0001' })

      expect(tool_calls.first['$session_id']).to eq(CHATGPT_SESSION)
    end

    it 'falls back to a minted handle when the id is not its row\'s shape' do
      instrument
      texts = call_search(user_agent: CODEX, meta: { 'sessionId' => 'not-a-uuid' })

      expect(texts.last).to match(HANDLE_BLOCK)
    end

    it 'mints a handle-free client no handle, and its sessionless calls stand alone' do
      instrument
      first = call_search(user_agent: CHATGPT, meta: { 'openai/session' => '' })
      second = call_search(user_agent: CHATGPT, id: 3)

      expect([first, second]).to eq([['found'], ['found']])
      sessions = tool_calls.map { |call| call['$session_id'] }
      expect(sessions.uniq.size).to eq(2)
    end

    it 'derives Codex and VS Code sessions from their ids' do
      instrument
      codex = call_search(user_agent: CODEX, meta: { 'sessionId' => '019A4F2E-1C3D-7B8A-9E0F-1A2B3C4D5E6F' })
      vscode = call_search(meta: {
                             'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
                             'io.modelcontextprotocol/clientInfo' => { 'name' => 'Visual Studio Code', 'version' => '1.100.0' },
                             'io.modelcontextprotocol/clientCapabilities' => {},
                             'vscode.conversationId' => '3f1c2b7e-8d4a-4c6b-9a1e-5f2d7c8b9a0e'
                           }, headers: { 'mcp-protocol-version' => '2026-07-28', 'mcp-method' => 'tools/call',
                                         'mcp-name' => 'search_docs' }, id: 3)

      expect([codex, vscode]).to eq([['found'], ['found']])
      expect(tool_calls.map { |call| call['$session_id'] }).to eq([CODEX_SESSION, 'ses_0571acb894e6753d33e37e5c2b327c59'])
    end

    it 'reads a key only from the client that defines it' do
      instrument
      texts = call_search(user_agent: 'example-client/1.0',
                          meta: { 'sessionId' => '019a4f2e-1c3d-7b8a-9e0f-1a2b3c4d5e6f', 'openai/session' => 'v1/conv-example-0001' })

      expect(texts.last).to match(HANDLE_BLOCK)
      call = tool_calls.first
      expect([CODEX_SESSION, CHATGPT_SESSION]).not_to include(call['$session_id'])
      expect(call['$mcp_session_source']).to eq('conversation')
    end

    it 'advertises no conversation_id to a handle-free client and keeps stripping it for others' do
      instrument
      expect(list_tools(CHATGPT)['search_docs']).not_to include('conversation_id')
      expect(list_tools(CODEX)['search_docs']).to include('conversation_id')

      list_tools(CHATGPT)
      call_search(user_agent: CODEX, arguments: { query: 'flags', conversation_id: '0190f0e8-7a6b-7c3d-9e4f-5a6b7c8d9e0f' })
      expect(PostHogMcpSearchDocsTool.received).to eq(query: 'flags')
    end

    it 'recognizes a client by the name its replayed token carries, not by another client\'s handshake' do
      instrument
      init = lambda do |name|
        body = rpc(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: name, version: '1' } })
        transport.call(env_for(body))[1]['mcp-session-id']
      end
      example_token = init.call('example-client')
      codex_token = init.call('codex-mcp-client')
      meta = { 'sessionId' => '019a4f2e-1c3d-7b8a-9e0f-1a2b3c4d5e6f' }
      call_search(meta: meta, headers: { 'mcp-session-id' => codex_token })
      call_search(meta: meta, headers: { 'mcp-session-id' => example_token }, id: 3)
      call_search(meta: meta, id: 4)

      sessions = tool_calls.map { |call| call['$session_id'] }
      expect(sessions.map { |session| session == CODEX_SESSION }).to eq([true, false, false])
    end

    {
      'legacy' => [{}, {}],
      '2026-07-28' => [
        { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28', 'io.modelcontextprotocol/clientCapabilities' => {},
          'io.modelcontextprotocol/clientInfo' => { 'name' => 'example-client', 'version' => '1' } },
        { 'mcp-protocol-version' => '2026-07-28', 'mcp-method' => 'tools/call', 'mcp-name' => 'search_docs' }
      ]
    }.each do |era, (meta, headers)|
      it "gives every sessionless #{era} stateless HTTP request a fresh generated session" do
        instrument(enable_conversation_id: false)
        call_search(meta: meta, headers: headers)
        call_search(meta: meta, headers: headers, id: 3)

        calls = tool_calls
        expect(calls.map { |call| call['$mcp_session_source'] }).to eq(%w[generated generated])
        expect(calls.map { |call| call['$session_id'] }.uniq.size).to eq(2)
        expect(calls.map { |call| call['$session_id'] }).to all(match(/\Ases_\h{8}-\h{4}-7/))
      end

      next if meta.empty?

      it "mints a handle for a sessionless #{era} request on a stateful transport" do
        stateful = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: false, enable_json_response: true)
        instrument
        params = { name: 'search_docs', arguments: { query: 'flags' }, _meta: meta }
        texts = parse(stateful.call(env_for(rpc(2, 'tools/call', params), headers)))['result']['content'].map { |block| block['text'] }

        expect(texts.last).to match(HANDLE_BLOCK)
        expect(tool_calls.first['$mcp_session_source']).to eq('conversation')
      end
    end

    it 'labels a replayed token as transport and mints no handle beside it' do
      instrument
      token = PostHog::MCP.encode_session_id(PostHog::MCP::SessionTokenPayload.new(session_id: 'ses_first'))
      texts = call_search(headers: { 'mcp-session-id' => token })

      expect(texts).to eq(['found'])
      call = tool_calls.first
      expect(call.values_at('$session_id', '$mcp_session_source')).to eq(%w[ses_first transport])
    end

    {
      'ChatGPT' => [CHATGPT, { 'openai/session' => 'v1/conv-canary-0001' }],
      'Codex' => [CODEX, { 'sessionId' => '019a4f2e-1c3d-7b8a-9e0f-cafecafecafe' }],
      'invalid Codex' => [CODEX, { 'sessionId' => 'not-a-uuid-canary' }]
    }.each do |name, (user_agent, meta)|
      it "sends no #{name} conversation id in any property" do
        instrument(identify: ->(_request, _extra) { { distinct_id: 'user-1' } })
        call_search(user_agent: user_agent, meta: meta)

        events = drain_events(client)
        expect(events_named(events, '$mcp_tool_call').size).to eq(1)
        expect(events.map { |event| JSON.generate(event) }.grep(/#{Regexp.escape(meta.values.first)}/)).to eq([])
      end
    end

    {
      'tools/list' => ['tools/list', {}],
      'resources/read' => ['resources/read', { uri: 'file:///docs.txt' }],
      'prompts/get' => ['prompts/get', { name: 'greeting' }]
    }.each do |method, (rpc_method, params)|
      it "sends no VS Code conversation id on #{method}" do
        seen = []
        instrument(event_properties: lambda { |request, _extra|
          seen << JSON.generate(request)
          nil
        })
        canary = %w[v1 conv canary 0002].join('-')
        server.handle(rpc(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: {},
                                             clientInfo: { name: 'Visual Studio Code', version: '1' } }))
        server.handle(rpc(2, rpc_method, params.merge(_meta: { 'vscode.conversationId' => canary })))

        events = drain_events(client)
        expect(seen).not_to be_empty
        expect((seen + events.map { |event| JSON.generate(event) }).grep(/#{canary}/)).to eq([])
      end
    end

    it 'labels the $identify event with the session source' do
      instrument(identify: ->(_request, _extra) { { distinct_id: 'user-1' } })
      call_search(user_agent: CHATGPT, meta: { 'openai/session' => 'v1/conv-example-0001' })

      identify = events_named(drain_events(client), '$identify').first
      expect(identify[:properties]['$mcp_session_source']).to eq('client_metadata')
    end

    it 'gives a capture outside any call a session after a first stdio call carrying a client conversation id' do
      analytics = PostHog::MCP.instrument(server, client, enable_conversation_id: false)
      meta = { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28', 'io.modelcontextprotocol/clientCapabilities' => {},
               'io.modelcontextprotocol/clientInfo' => { 'name' => 'Visual Studio Code', 'version' => '1.100.0' },
               'vscode.conversationId' => '3f1c2b7e-8d4a-4c6b-9a1e-5f2d7c8b9a0e' }
      server.handle(rpc(1, 'tools/call', { name: 'search_docs', arguments: { query: 'flags' }, _meta: meta }))
      analytics.capture('outside_call')

      outside = events_named(drain_events(client), 'outside_call').first
      expect(outside[:properties]['$session_id']).to match(/\Ases_/)
    end

    {
      'keeps a connection session a client-id call kept active' => [[0, 20, 40, 45], true],
      'rolls a connection session over after 30 idle minutes, even under a client-id call' => [[0, 40, 41], false]
    }.each do |behavior, (minutes, same)|
      it behavior do
        instrument(enable_conversation_id: false)
        start = Time.now
        server.handle(rpc(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: {},
                                             clientInfo: { name: 'Visual Studio Code', version: '1' } }))
        minutes.each_with_index do |minute, index|
          allow(Time).to receive(:now).and_return(start + (minute * 60))
          params = { name: 'search_docs', arguments: { query: 'flags' } }
          params[:_meta] = { 'vscode.conversationId' => '3f1c2b7e-8d4a-4c6b-9a1e-5f2d7c8b9a0e' } unless [0, minutes.size - 1].include?(index)
          server.handle(rpc(index + 2, 'tools/call', params))
        end

        sessions = tool_calls.map { |call| call['$session_id'] }
        expect(sessions.first == sessions.last).to eq(same)
      end
    end

    context 'custom events captured during a call' do
      def custom_events(events)
        events_named(events, 'docs_searched').map { |event| [event[:properties]['$session_id'], event[:properties]['$mcp_session_source']] }
      end

      def call_sessions(events)
        events_named(events, '$mcp_tool_call').map { |event| [event[:properties]['$session_id'], event[:properties]['$mcp_session_source']] }
      end

      it 'keeps that call\'s session while another call runs' do
        instrument(enable_conversation_id: false)
        token = PostHog::MCP.encode_session_id(PostHog::MCP::SessionTokenPayload.new(session_id: 'ses_first'))
        other = nil
        PostHogMcpSearchDocsTool.before_capture = lambda do
          PostHogMcpSearchDocsTool.before_capture = nil
          other = Thread.new { call_search(id: 3) }
          expect(other.join(5)).to eq(other)
        end
        call_search(headers: { 'mcp-session-id' => token })

        events = drain_events(client)
        expect(custom_events(events)).to match_array(call_sessions(events))
        expect(custom_events(events)).to include(%w[ses_first transport])
      ensure
        other&.join(2)
      end

      it 'sends an event captured through another server\'s handle to that server\'s client' do
        instrument
        other_client = new_test_client
        other_server = MCP::Server.new(name: 'other-server', version: '1.0.0')
        other_analytics = PostHog::MCP.instrument(other_server, other_client)
        PostHogMcpSearchDocsTool.before_capture = -> { other_analytics.capture('other_event') }
        call_search

        expect(events_named(drain_events(client), 'other_event')).to be_empty
        expect(events_named(drain_events(other_client), 'other_event').size).to eq(1)
      end

      it 'keeps a held event with its own call when the tool dispatches to another instrumented server' do
        instrument
        other_client = new_test_client
        other_server = MCP::Server.new(name: 'other-server', version: '1.0.0')
        PostHog::MCP.instrument(other_server, other_client)
        PostHogMcpSearchDocsTool.before_capture = lambda do
          PostHogMcpSearchDocsTool.analytics.capture('outer_event')
          other_server.handle({ jsonrpc: '2.0', id: 9, method: 'resources/list' })
        end
        call_search

        expect(events_named(drain_events(other_client), 'outer_event')).to be_empty
        events = drain_events(client)
        expect(custom_events(events)).to eq(call_sessions(events))
        expect(events_named(events, 'outer_event').size).to eq(1)
      end

      {
        'an anonymous outer call' => ->(_request, _extra) {},
        'an identified outer call' => ->(_request, _extra) { { distinct_id: 'user-1' } }
      }.each do |outer, identify|
        it "leaves #{outer}'s scope untouched while a nested dispatch runs" do
          instrument(identify: identify)
          other_server = MCP::Server.new(name: 'other-server', version: '1.0.0')
          PostHog::MCP.instrument(other_server, new_test_client)
          outer_scope = nil
          snapshot = nil
          during = nil
          other_server.resources_list_handler { |_params| (during = outer_scope.dup) && [] }
          PostHogMcpSearchDocsTool.before_capture = lambda do
            outer_scope = PostHog::MCP::RequestScope.current
            snapshot = outer_scope.dup
            other_server.handle({ jsonrpc: '2.0', id: 9, method: 'resources/list' })
          end
          call_search

          expect(snapshot).to include(:owner, :session_id, :actor, :held)
          expect(during).to eq(snapshot)
          expect(outer_scope).to include(actor: snapshot[:actor])
        end
      end

      it 'keeps a spawned thread\'s custom event with the outer call while a nested dispatch runs' do
        instrument
        other_server = MCP::Server.new(name: 'other-server', version: '1.0.0')
        PostHog::MCP.instrument(other_server, new_test_client)
        go = Queue.new
        thread = nil
        other_server.resources_list_handler do |_params|
          go << true
          thread.join(5)
          []
        end
        PostHogMcpSearchDocsTool.before_capture = lambda do
          thread = Thread.new do
            go.pop
            PostHogMcpSearchDocsTool.analytics.capture('thread_event')
          end
          other_server.handle({ jsonrpc: '2.0', id: 9, method: 'resources/list' })
        end
        call_search

        events = drain_events(client)
        expect(events_named(events, 'thread_event').map { |e| e[:properties]['$session_id'] }).to eq(call_sessions(events).map(&:first))
      ensure
        thread&.join(2)
      end

      it 'carries the client conversation session' do
        instrument
        call_search(user_agent: CHATGPT, meta: { 'openai/session' => 'v1/conv-example-0001' })

        expect(custom_events(drain_events(client))).to eq([[CHATGPT_SESSION, 'client_metadata']])
      end

      it 'carries the session and identity of the handle its call delivered' do
        instrument(identify: ->(_request, _extra) { { distinct_id: 'user-1' } })
        texts = call_search

        handle = JSON.parse(texts.last)['conversation_id']
        events = drain_events(client)
        expect(custom_events(events)).to eq([[PostHog::MCP.derive_session_id_from_conversation(handle), 'conversation']])
        expect(custom_events(events)).to eq(call_sessions(events))
        expect(events_named(events, 'docs_searched').map { |event| event[:distinct_id] }).to eq(['user-1'])
      end

      it 'sends custom events past the hold bound at once, and warns once' do
        logs = []
        instrument(logger: ->(message) { logs << message })
        PostHogMcpSearchDocsTool.before_capture = -> { 1001.times { PostHogMcpSearchDocsTool.analytics.capture('docs_searched') } }
        call_search

        expect(events_named(drain_events(client), 'docs_searched').size).to eq(1002)
        expect(logs.grep(/custom events/).size).to eq(1)
      end

      it 'keeps a held event\'s nested properties as they were when captured' do
        instrument
        filters = ['flags']
        PostHogMcpSearchDocsTool.before_capture = lambda do
          PostHogMcpSearchDocsTool.analytics.capture('filtered', { filters: filters })
          filters << 'changed after capture'
        end
        call_search

        filtered = events_named(drain_events(client), 'filtered').first
        expect(filtered[:properties]['filters']).to eq(['flags'])
      end

      it 'sends custom events past the held byte budget at once' do
        instrument
        PostHogMcpSearchDocsTool.before_capture = lambda do
          300.times { PostHogMcpSearchDocsTool.analytics.capture('bulky', { blob: 'x' * 65_536 }) }
        end
        call_search

        sources = events_named(drain_events(client), 'bulky').map { |event| event[:properties]['$mcp_session_source'] }
        expect(sources.size).to eq(300)
        expect(sources.tally.keys).to contain_exactly('conversation', 'generated')
      end

      it 'carries the session the call recorded when the tool raises before delivering its handle' do
        instrument
        PostHogMcpSearchDocsTool.before_capture = lambda do
          PostHogMcpSearchDocsTool.analytics.capture('docs_searched')
          raise 'search backend down'
        end
        transport.call(env_for(rpc(2, 'tools/call', { name: 'search_docs', arguments: { query: 'flags' } })))

        events = drain_events(client)
        expect(custom_events(events)).to eq(call_sessions(events))
        expect(custom_events(events).map(&:last)).to eq(['generated'])
      end
    end
  end
end
# rubocop:enable Layout/LineLength
