# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require_relative 'spec_helper'
require 'rack'
require 'stringio'

class PostHogMcpHttpSpecTool < MCP::Tool
  tool_name 'ping_tool'
  input_schema(properties: {})
  class << self
    def call(**)
      MCP::Tool::Response.new([{ type: 'text', text: 'pong' }])
    end
  end
end

class PostHogMcpHttpSpecCaptureTool < MCP::Tool
  tool_name 'capture_tool'
  input_schema(properties: {})
  class << self
    attr_accessor :analytics, :before_capture

    def call(**)
      before_capture&.call
      analytics.capture('in_tool_event', { from: 'tool' })
      MCP::Tool::Response.new([{ type: 'text', text: 'captured' }])
    end
  end
end

RSpec.describe 'PostHog::MCP over Streamable HTTP' do
  let(:client) { new_test_client }
  let(:server) { MCP::Server.new(name: 'http-server', version: '1.0.0', tools: [PostHogMcpHttpSpecTool]) }

  before { allow(Kernel).to receive(:warn) }

  def env_for(body, headers = {})
    env = {
      'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/', 'SCRIPT_NAME' => '', 'QUERY_STRING' => '',
      'SERVER_NAME' => 'localhost', 'SERVER_PORT' => '80', 'HTTP_HOST' => 'localhost', 'rack.url_scheme' => 'http',
      'HTTP_ACCEPT' => 'application/json, text/event-stream', 'CONTENT_TYPE' => 'application/json',
      'rack.input' => StringIO.new(JSON.generate(body)), 'rack.errors' => StringIO.new
    }
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    env
  end

  def initialize_body(id = 1, version = '2025-06-18')
    rpc(id, 'initialize', { protocolVersion: version, capabilities: {}, clientInfo: { name: 'claude-code', version: '1.2.3' } })
  end

  def parse(response)
    JSON.parse(response[2].respond_to?(:join) ? response[2].join : response[2].to_s)
  end

  context 'stateless mode' do
    let(:transport) { MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true, enable_json_response: true) }

    it 'mints a session token on initialize, recovers it on replay, and stamps transport identity' do
      PostHog::MCP.instrument(server, client)
      response = transport.call(env_for(initialize_body, 'user-agent' => 'claude-code/2.1.0 (cli)', 'x-anthropic-client' => 'cli'))
      expect(response[0]).to eq(200)
      token = response[1]['mcp-session-id']
      payload = PostHog::MCP.decode_session_id(token)
      expect(payload.session_id).to match(/\Ases_/)
      expect(payload.client_name).to eq('claude-code')
      expect(payload.client_version).to eq('1.2.3')
      expect(payload.protocol_version).to eq('2025-06-18')

      replay = transport.call(env_for(rpc(2, 'tools/call', { name: 'ping_tool', arguments: {} }),
                                      'mcp-session-id' => token, 'user-agent' => 'claude-code/2.1.0 (cli)',
                                      'x-anthropic-client' => 'cli'))
      expect(parse(replay)['result']['content'][0]['text']).to eq('pong')
      expect(replay[1]['mcp-session-id']).to be_nil

      events = drain_events(client)
      init = events.find { |e| e[:event] == '$mcp_initialize' }
      expect(init[:properties]['$session_id']).to eq(payload.session_id)
      expect(init[:properties]).to include('$mcp_client_user_agent' => 'claude-code/2.1.0 (cli)', '$mcp_vendor_client' => 'cli')
      call = events.find { |e| e[:event] == '$mcp_tool_call' }
      expect(call[:properties]).to include('$session_id' => payload.session_id, '$mcp_client_name' => 'claude-code',
                                           '$mcp_client_version' => '1.2.3', '$mcp_protocol_version' => '2025-06-18',
                                           '$mcp_client_user_agent' => 'claude-code/2.1.0 (cli)')
      expect(events.count { |e| e[:event] == '$mcp_initialize' }).to eq(1)
    end

    it 'does not mint for modern-era handshakes and warns once for tokenless requests' do
      logs = []
      PostHog::MCP.instrument(server, client, logger: ->(m) { logs << m })
      response = transport.call(env_for(initialize_body(1, 'draft')))
      expect(response[1]['mcp-session-id']).to be_nil
      2.times { |i| transport.call(env_for(rpc(i + 2, 'tools/call', { name: 'ping_tool', arguments: {} }))) }
      expect(logs.count { |m| m.include?('fragment across requests') }).to eq(1)
    end

    it 'leaves uninstrumented servers alone' do
      response = transport.call(env_for(initialize_body))
      expect(response[0]).to eq(200)
      expect(response[1]['mcp-session-id']).to be_nil
      expect(client.queued_messages).to eq(0)
    end
  end

  context 'stateful mode' do
    let(:transport) { MCP::Server::Transports::StreamableHTTPTransport.new(server, enable_json_response: true) }

    it 'hashes the transport session id deterministically across requests' do
      PostHog::MCP.instrument(server, client)
      response = transport.call(env_for(initialize_body))
      session_id = response[1]['mcp-session-id']
      expect(PostHog::MCP.decode_session_id(session_id)).to be_nil
      transport.call(env_for(rpc(2, 'tools/call', { name: 'ping_tool', arguments: {} }), 'mcp-session-id' => session_id))
      events = drain_events(client)
      expected = PostHog::MCP.derive_session_id_from_mcp_session(session_id)
      expect(events.map { |e| e[:properties]['$session_id'] }.uniq).to eq([expected])
      expect(events.map { |e| e[:event] }).to eq(['$mcp_initialize', '$mcp_tool_call'])
    ensure
      transport.close
    end
  end

  context 'custom events captured inside a tool body' do
    let(:server) do
      MCP::Server.new(name: 'http-server', version: '1.0.0', tools: [PostHogMcpHttpSpecTool, PostHogMcpHttpSpecCaptureTool])
    end
    let(:transport) { MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true, enable_json_response: true) }
    let(:identify) { ->(_request, extra) { { distinct_id: extra['headers']['user-agent'] } } }

    before do
      PostHogMcpHttpSpecCaptureTool.analytics = PostHog::MCP.instrument(server, client, identify: identify)
      PostHogMcpHttpSpecCaptureTool.before_capture = nil
    end

    def initialize_as(user)
      transport.call(env_for(initialize_body, 'user-agent' => user))[1]['mcp-session-id']
    end

    def call_capture_tool_as(user, token, id: 2)
      transport.call(env_for(rpc(id, 'tools/call', { name: 'capture_tool', arguments: {} }), 'mcp-session-id' => token, 'user-agent' => user))
    end

    # distinct_id => $session_id for every event with the given name
    def attribution(events, name)
      events.select { |e| e[:event] == name }.to_h { |e| [e[:distinct_id], e[:properties]['$session_id']] }
    end

    it 'attributes the event to the caller, not to the last request the server finished' do
      alice = initialize_as('alice')
      initialize_as('bob')
      call_capture_tool_as('alice', alice)

      events = drain_events(client)
      expect(attribution(events, 'in_tool_event')).to eq('alice' => PostHog::MCP.decode_session_id(alice).session_id)
      expect(attribution(events, 'in_tool_event')).to eq(attribution(events, '$mcp_tool_call'))
    end

    it 'attributes the event to the caller while another request runs to completion on the same server' do
      alice = initialize_as('alice')
      bob = initialize_as('bob')
      bob_finished = Queue.new
      PostHogMcpHttpSpecCaptureTool.before_capture = lambda do
        # Runs inside Alice's tool body: let Bob's whole request finish before Alice captures.
        PostHogMcpHttpSpecCaptureTool.before_capture = nil
        Thread.new do
          call_capture_tool_as('bob', bob, id: 3)
          bob_finished << true
        end
        bob_finished.pop
      end
      call_capture_tool_as('alice', alice)

      events = drain_events(client)
      expect(attribution(events, 'in_tool_event')).to eq(
        'alice' => PostHog::MCP.decode_session_id(alice).session_id,
        'bob' => PostHog::MCP.decode_session_id(bob).session_id
      )
      expect(attribution(events, 'in_tool_event')).to eq(attribution(events, '$mcp_tool_call'))
    end
  end
end

RSpec.describe PostHog::MCP::RackMiddleware do
  let(:app) { ->(_env) { [200, { 'content-type' => 'application/json' }, ['{}']] } }
  let(:middleware) { described_class.new(app) }

  def env_for(body, headers = {})
    env = { 'REQUEST_METHOD' => 'POST', 'rack.input' => StringIO.new(body) }
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    env
  end

  it 'mints on a tokenless initialize and leaves the body readable' do
    seen_body = nil
    inner = lambda do |env|
      seen_body = env['rack.input'].read
      [200, {}, []]
    end
    body = JSON.generate(rpc(1, 'initialize', { protocolVersion: '2025-06-18', clientInfo: { name: 'c', version: '1' } }))
    env = env_for(body)
    status, headers, = described_class.new(inner).call(env)
    expect(status).to eq(200)
    payload = PostHog::MCP.decode_session_id(headers['mcp-session-id'])
    expect(payload.client_name).to eq('c')
    expect(env['posthog_mcp.session']).to eq(payload)
    expect(seen_body).to eq(body)
  end

  it 'does not attach the token when the app rejects the initialize' do
    failing = ->(_env) { [400, {}, ['{}']] }
    body = JSON.generate(rpc(1, 'initialize', { protocolVersion: '2025-06-18', clientInfo: { name: 'c', version: '1' } }))
    env = env_for(body)
    _, headers, = described_class.new(failing).call(env)
    expect(headers['mcp-session-id']).to be_nil
    expect(env['posthog_mcp.session']).to be_nil
  end

  it 'never clobbers a replayed header and skips non-initialize or modern requests' do
    token = PostHog::MCP.encode_session_id(session_id: 'ses_replayed')
    env = env_for('{}', 'mcp-session-id' => token)
    _, headers, = middleware.call(env)
    expect(headers['mcp-session-id']).to be_nil
    expect(env['posthog_mcp.session'].session_id).to eq('ses_replayed')

    _, headers, = middleware.call(env_for(JSON.generate(rpc(1, 'tools/list'))))
    expect(headers['mcp-session-id']).to be_nil
    _, headers, = middleware.call(env_for(JSON.generate(rpc(1, 'initialize', { protocolVersion: '2026-07-28' }))))
    expect(headers['mcp-session-id']).to be_nil
    _, headers, = middleware.call(env_for('not json'))
    expect(headers['mcp-session-id']).to be_nil
  end
end
# rubocop:enable Layout/LineLength
