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

    it 'gives every sessionless stateless HTTP request a fresh generated session' do
      instrument(enable_conversation_id: false)
      call_search
      call_search(id: 3)

      calls = tool_calls
      expect(calls.map { |call| call['$mcp_session_source'] }).to eq(%w[generated generated])
      expect(calls.map { |call| call['$session_id'] }.uniq.size).to eq(2)
    end

    it 'labels a replayed token and a transport session id as transport' do
      instrument(enable_conversation_id: false)
      token = PostHog::MCP.encode_session_id(PostHog::MCP::SessionTokenPayload.new(session_id: 'ses_first'))
      call_search(headers: { 'mcp-session-id' => token })

      call = tool_calls.first
      expect(call.values_at('$session_id', '$mcp_session_source')).to eq(%w[ses_first transport])
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
