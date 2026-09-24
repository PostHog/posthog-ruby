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
      PostHog::MCP.instrument(server, client, enable_conversation_id: false)
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
      PostHog::MCP.instrument(server, client, enable_conversation_id: false)
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

    it 'runs get_more_tools through the real request lifecycle so in-flight entries are released' do
      PostHog::MCP.instrument(
        server, client, report_missing: true, capture_model: false, enable_conversation_id: false
      )
      session_id = transport.call(env_for(initialize_body))[1]['mcp-session-id']
      3.times do |i|
        response = transport.call(env_for(rpc(i + 2, 'tools/call', { name: 'get_more_tools', arguments: { context: 'csv export' } }),
                                          'mcp-session-id' => session_id))
        expect(response[0]).to eq(200)
        expect(parse(response)['result']['content'][0]['text']).to include('Unfortunately')
      end
      server_session = transport.instance_variable_get(:@sessions).fetch(session_id).fetch(:server_session)
      expect((2..4).none? { |id| server_session.in_flight?(id) }).to be(true)
      expect(drain_events(client).count { |e| e[:event] == '$mcp_missing_capability' }).to eq(3)
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
      PostHogMcpHttpSpecCaptureTool.analytics = PostHog::MCP.instrument(
        server, client, identify: identify, enable_conversation_id: false
      )
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

# An input the middleware must never touch: reading it fails the example.
class PostHogMcpUnreadableInput
  def read(*) = raise('the middleware read the request body')
  def gets(*) = raise('the middleware read the request body')
  def each(*) = raise('the middleware read the request body')
end

RSpec.describe PostHog::MCP::RackMiddleware do
  let(:client) { new_test_client }
  let(:server) { MCP::Server.new(name: 'rack-server', version: '1.0.0', tools: [PostHogMcpHttpSpecTool]) }

  before { allow(Kernel).to receive(:warn) }

  def env_for(body, headers = {})
    env = { 'REQUEST_METHOD' => 'POST', 'rack.input' => StringIO.new(body) }
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    env
  end

  def initialize_json(version = '2025-06-18')
    JSON.generate(rpc(1, 'initialize', { protocolVersion: version, capabilities: {}, clientInfo: { name: 'claude-code', version: '1.2.3' } }))
  end

  # A dispatcher that reads the body itself, exactly as a custom Rack stack does.
  def dispatching_app(status: 200, body: nil)
    lambda do |env|
      request = JSON.parse(env['rack.input'].read)
      [status, { 'content-type' => 'application/json' }, [body || server.handle_json(JSON.generate(request))]]
    end
  end

  it 'mints from the instrumented server without reading the request body' do
    PostHog::MCP.instrument(server, client, enable_conversation_id: false)
    env = { 'REQUEST_METHOD' => 'POST', 'rack.input' => PostHogMcpUnreadableInput.new }
    app = ->(_e) { [200, { 'content-type' => 'application/json' }, [server.handle_json(initialize_json)]] }
    status, headers, = described_class.new(app).call(env)

    expect(status).to eq(200)
    payload = PostHog::MCP.decode_session_id(headers['mcp-session-id'])
    expect(payload.session_id).to match(/\Ases_/)
    expect(payload.client_name).to eq('claude-code')
    expect(payload.protocol_version).to eq('2025-06-18')
    expect(env['posthog_mcp.session']).to eq(payload)
    expect(drain_events(client).find { |e| e[:event] == '$mcp_initialize' }[:properties]['$session_id'])
      .to eq(payload.session_id)
  end

  it 'publishes the request headers so a server below it sees the HTTP context' do
    PostHog::MCP.instrument(server, client, enable_conversation_id: false)
    env = env_for(initialize_json, 'user-agent' => 'claude-code/2.1.0 (cli)', 'x-anthropic-client' => 'cli')
    _, headers, = described_class.new(dispatching_app).call(env)
    token = headers['mcp-session-id']

    replay = env_for(JSON.generate(rpc(2, 'tools/call', { name: 'ping_tool', arguments: {} })),
                     'mcp-session-id' => token, 'user-agent' => 'claude-code/2.1.0 (cli)')
    _, replay_headers, = described_class.new(dispatching_app).call(replay)
    expect(replay_headers['mcp-session-id']).to be_nil
    expect(replay['posthog_mcp.session'].session_id).to eq(PostHog::MCP.decode_session_id(token).session_id)

    events = drain_events(client)
    expect(events.map { |e| e[:properties]['$session_id'] }.uniq).to eq([PostHog::MCP.decode_session_id(token).session_id])
    expect(events.last[:properties]).to include('$mcp_client_name' => 'claude-code', '$mcp_client_version' => '1.2.3',
                                                '$mcp_client_user_agent' => 'claude-code/2.1.0 (cli)')
  end

  it 'mints nothing for a modern-era handshake or one the server rejects' do
    PostHog::MCP.instrument(server, client)
    env = env_for(initialize_json('draft'))
    _, headers, = described_class.new(dispatching_app).call(env)
    expect(headers['mcp-session-id']).to be_nil
    expect(env['posthog_mcp.session']).to be_nil

    # A JSON-RPC error rides on a 200, and nothing below minted a token for it.
    rejected = JSON.generate({ jsonrpc: '2.0', id: 1, error: { code: -32_602, message: 'Unsupported protocol version' } })
    env = env_for(initialize_json)
    _, headers, = described_class.new(dispatching_app(body: rejected)).call(env)
    expect(headers['mcp-session-id']).to be_nil
    expect(env['posthog_mcp.session']).to be_nil
  end

  it 'lets a hand-rolled dispatcher mint the session it captures against' do
    minted = nil
    app = lambda do |env|
      params = JSON.parse(env['rack.input'].read)['params']
      minted = env['posthog_mcp.mint'].call(client_name: params['clientInfo']['name'],
                                            client_version: params['clientInfo']['version'],
                                            protocol_version: params['protocolVersion'])
      [200, {}, ['{}']]
    end
    env = env_for(initialize_json)
    _, headers, = described_class.new(app).call(env)

    expect(minted.client_name).to eq('claude-code')
    expect(PostHog::MCP.decode_session_id(headers['mcp-session-id'])).to eq(minted)
    expect(env['posthog_mcp.session']).to eq(minted)
    expect(env).not_to have_key('posthog_mcp.mint')
  end

  it 'refuses to mint for a modern-era client' do
    minted = :unset
    app = lambda do |env|
      minted = env['posthog_mcp.mint'].call(client_name: 'c', protocol_version: '2026-07-28')
      [200, {}, ['{}']]
    end
    _, headers, = described_class.new(app).call(env_for(initialize_json('2026-07-28')))
    expect(minted).to be_nil
    expect(headers['mcp-session-id']).to be_nil
  end

  it 'withholds a token the client cannot use when the request then fails' do
    app = lambda do |env|
      env['posthog_mcp.mint'].call(client_name: 'c', protocol_version: '2025-06-18')
      [400, {}, ['{}']]
    end
    env = env_for(initialize_json)
    _, headers, = described_class.new(app).call(env)
    expect(headers['mcp-session-id']).to be_nil
    expect(env['posthog_mcp.session']).to be_nil
  end

  it 'attaches the token to a streaming body and never clobbers a replayed header' do
    PostHog::MCP.instrument(server, client)
    streaming = Class.new do
      def initialize(json) = @json = json
      def each = yield("data: #{@json}\n\n")
    end
    sse = lambda do |_env|
      [200, { 'content-type' => 'text/event-stream' }, streaming.new(server.handle_json(initialize_json))]
    end
    _, headers, = described_class.new(sse).call(env_for(initialize_json))
    expect(headers['mcp-session-id']).not_to be_nil

    token = PostHog::MCP.encode_session_id(session_id: 'ses_replayed')
    replay = env_for('{}', 'mcp-session-id' => token)
    app = ->(env) { [200, {}, [env.key?('posthog_mcp.mint') ? 'hook' : 'no-hook']] }
    _, headers, body = described_class.new(app).call(replay)
    expect(headers['mcp-session-id']).to be_nil
    expect(replay['posthog_mcp.session'].session_id).to eq('ses_replayed')
    expect(body).to eq(['no-hook'])
  end
end

# rubocop:enable Layout/LineLength
