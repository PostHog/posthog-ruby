# frozen_string_literal: true

require_relative 'spec_helper'

class PostHogMcpSpecConfirmTool < MCP::Tool
  tool_name 'delete_project'
  description 'Deletes a project'
  class << self
    def call(server_context:, **)
      return MCP::Tool::Response.new([{ type: 'text', text: 'deleted' }]) if server_context.input_response('z_confirm')

      round
    end

    def round
      confirm = { message: 'Delete project secret-42?', requestedSchema: { type: 'object', properties: {} } }
      MCP::Server::InputRequiredResult.new(input_requests: {
                                             z_confirm: { method: 'elicitation/create', params: confirm },
                                             a_roots: { method: 'roots/list' }
                                           })
    end
  end
end

class PostHogMcpSpecStateOnlyTool < MCP::Tool
  tool_name 'retry_later'
  class << self
    def call(server_context:, **) # rubocop:disable Lint/UnusedMethodArgument -- the gem passes it to opt in
      MCP::Server::InputRequiredResult.new(request_state: 'state-only')
    end
  end
end

RSpec.describe 'PostHog::MCP input_required rounds' do
  let(:client) { new_test_client }
  let(:server) do
    MCP::Server.new(name: 'spec-server', version: '9.9.9',
                    tools: [PostHogMcpSpecConfirmTool, PostHogMcpSpecStateOnlyTool])
  end
  let(:modern_meta) do
    { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientCapabilities' => { elicitation: {}, roots: {} } }
  end

  before { PostHog::MCP.instrument(server, client) }

  def call(id, name, **params)
    server.handle(rpc(id, 'tools/call', { name: name, arguments: {}, _meta: modern_meta, **params }))
  end

  it 'records a 2026-07-28 round as $mcp_input_required and only the retry as a tool call' do
    expect(call(1, 'delete_project')[:result][:resultType]).to eq('input_required')
    events = drain_events(client)
    expect(events.map { |e| e[:event] }).to eq(['$mcp_input_required'])
    expect(events[0][:properties]).to include('$mcp_tool_name' => 'delete_project',
                                              '$mcp_input_request_methods' => ['roots/list', 'elicitation/create'],
                                              '$mcp_protocol_version' => '2026-07-28')
    expect(events[0][:properties]['$mcp_duration_ms']).to be >= 0
    expect(events[0][:properties]).not_to include('$mcp_is_error', '$mcp_resource_name', '$mcp_conversation_id')
    expect(events.to_s).not_to include('secret-42')

    answers = { z_confirm: { action: 'accept', content: {} }, a_roots: { roots: [] } }
    expect(call(2, 'delete_project', inputResponses: answers)[:result][:content][0][:text]).to eq('deleted')
    expect(drain_events(client).map { |e| e[:event] }).to eq(['$mcp_tool_call'])
  end

  it 'records no methods for a round that carries only requestState' do
    call(1, 'retry_later')
    round = events_named(drain_events(client), '$mcp_input_required')
    expect(round.size).to eq(1)
    expect(round[0][:properties]['$mcp_input_request_methods']).to eq([])
    expect(round.to_s).not_to include('state-only')
  end

  it 'records a round from a custom dispatcher with the methods read off the result' do
    mcp_client = PostHog::MCP::Client.new(api_key: 'phc_test', test_mode: true)
    expect(PostHog::MCP.input_request_methods({ content: [] })).to be_nil
    methods = PostHog::MCP.input_request_methods(PostHogMcpSpecConfirmTool.round)
    expect(methods).to eq(['roots/list', 'elicitation/create'])

    mcp_client.capture_input_required('delete_project', input_request_methods: methods, duration_ms: 3,
                                                        session_id: 'ses_123')
    event = mcp_client.dequeue_last_message
    expect(event[:event]).to eq('$mcp_input_required')
    expect(event[:properties]).to include('$mcp_tool_name' => 'delete_project',
                                          '$mcp_input_request_methods' => ['roots/list', 'elicitation/create'],
                                          '$mcp_duration_ms' => 3, '$session_id' => 'ses_123')
    expect(mcp_client.queued_messages).to eq(0)
  ensure
    mcp_client&.shutdown(timeout: 2)
  end
end
