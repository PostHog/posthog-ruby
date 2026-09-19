# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Client do
  let(:client) { described_class.new(api_key: 'phc_test', test_mode: true) }

  it 'captures tool calls with $lib override, anonymous distinct id and error scalars' do
    client.capture_tool_call('execute-sql', is_error: false, response: { ok: true })
    event = client.dequeue_last_message
    expect(event[:event]).to eq('$mcp_tool_call')
    expect(event[:distinct_id]).to eq('anonymous')
    expect(event[:properties]).to include('$process_person_profile' => false, '$lib' => 'posthog-ruby-mcp',
                                          '$lib_version' => PostHog::VERSION, '$mcp_is_error' => false)
    expect(event[:properties]).not_to have_key('$session_id')

    client.capture_tool_call('add', is_error: true, error: ArgumentError.new('bad input'), distinct_id: 'user-123',
                                    set_properties: { email: 'a@b.com' }, groups: { organization: 'org_1' })
    events = drain_events(client)
    expect(events.map { |e| e[:event] }).to eq(['$mcp_tool_call', '$exception'])
    props = events[0][:properties]
    expect(props).to include('$mcp_error_type' => 'ArgumentError', '$mcp_error_message' => 'bad input',
                             '$set' => { 'email' => 'a@b.com' }, '$groups' => { 'organization' => 'org_1' })
    expect(events[0][:distinct_id]).to eq('user-123')

    client.capture_tool_call('add', is_error: true, error: ArgumentError.new('bad input'), error_type: 'validation')
    expect(client.dequeue_last_message[:properties]['$mcp_error_type']).to eq('validation')
    client.dequeue_last_message

    client.capture_tool_call('add', is_error: true, error: 'upstream timed out')
    expect(client.dequeue_last_message[:properties]).to include('$mcp_error_type' => 'Error',
                                                                '$mcp_error_message' => 'upstream timed out')
    client.clear

    client.capture_tool_call('add', is_error: true, error: ArgumentError.new('x' * 5000))
    events = drain_events(client)
    message = events[0][:properties]['$mcp_error_message']
    expect(message.length).to eq(2051)
    expect(message).to eq(events[1][:properties]['$exception_list'][0]['value'])
  end

  it 'survives self-referential and oversized custom properties' do
    properties = { 'rows' => (1..10_000).to_a }
    properties['self'] = properties
    expect { client.capture_tool_call('add', is_error: false, properties: properties) }.not_to raise_error
    event = client.dequeue_last_message
    expect(event[:event]).to eq('$mcp_tool_call')
    expect(event[:properties]['self']).to eq('[Circular ~]')
    expect(event[:properties]['rows'].length).to be <= PostHog::MCP::Truncation::MAX_BREADTH + 1
  end

  it 'respects mcp_exception_autocapture: false and default error strings' do
    quiet = described_class.new(api_key: 'phc_test', test_mode: true, mcp_exception_autocapture: false)
    quiet.capture_tool_call('add', is_error: true)
    events = drain_events(quiet)
    expect(events.length).to eq(1)
    expect(events[0][:properties]['$mcp_error_message']).to eq('Tool add returned an error')
    quiet.capture_tools_list(is_error: true)
    expect(quiet.dequeue_last_message[:properties]['$mcp_error_message']).to eq('tools/list failed')
  end

  it 'captures initialize, tools list and missing capability' do
    client.capture_initialize(client_name: 'claude-code', client_version: '1.2.3', protocol_version: '2025-06-18',
                              distinct_id: 'user-123', duration_ms: 7)
    props = client.dequeue_last_message[:properties]
    expect(props).to include('$mcp_client_name' => 'claude-code', '$mcp_client_version' => '1.2.3',
                             '$mcp_protocol_version' => '2025-06-18', '$mcp_duration_ms' => 7)

    client.capture_tools_list(tool_names: %w[execute-sql query-logs get_more_tools], duration_ms: 3, distinct_id: 'u')
    props = client.dequeue_last_message[:properties]
    expect(props['$mcp_listed_tool_names']).to eq(%w[execute-sql query-logs get_more_tools])

    client.capture_missing_capability(context: '  wanted a tool to export to CSV ', distinct_id: 'u',
                                      llm_model: ' claude-opus-4-8 ')
    event = client.dequeue_last_message
    expect(event[:event]).to eq('$mcp_missing_capability')
    expect(event[:properties]).to include('$mcp_intent' => 'wanted a tool to export to CSV',
                                          '$mcp_intent_source' => 'context_parameter',
                                          '$mcp_resource_name' => 'get_more_tools',
                                          '$mcp_llm_model' => 'claude-opus-4-8',
                                          '$mcp_llm_model_source' => 'self_reported')
  end

  it 'prepares tool lists and tool calls' do
    tools = [{ name: 'a', inputSchema: { type: 'object', properties: {} } }, { name: 'get_more_tools' }]
    prepared = client.prepare_tool_list(tools, report_missing: true)
    expect(prepared.length).to eq(2)
    expect(prepared[0][:inputSchema][:properties]).to have_key(:context)
    expect(tools[0][:inputSchema][:properties]).to eq({})
    prepared = client.prepare_tool_list([tools[0]], context: false, report_missing: true)
    expect(prepared.map { |t| t[:name] }).to eq(%w[a get_more_tools])

    call = client.prepare_tool_call('search', { context: '  find it ', q: 'x' })
    expect(call.to_h).to eq(args: { q: 'x' }, intent: 'find it', intent_source: 'context_parameter',
                            is_missing_capability: false)
    expect(client.prepare_tool_call('get_more_tools').is_missing_capability).to be(true)
  end

  it 'advertises llm_model on every tool and on the virtual one when capture_model is on' do
    tools = [{ name: 'a', inputSchema: { type: 'object', properties: {} } }]
    prepared = client.prepare_tool_list(tools, capture_model: true, report_missing: true)
    expect(prepared[0][:inputSchema][:properties].keys).to eq(%i[context llm_model])
    expect(prepared[1][:name]).to eq('get_more_tools')
    expect(prepared[1][:inputSchema][:properties].keys).to eq(%i[context llm_model])
    expect(prepared[1][:inputSchema][:required]).to contain_exactly('context', 'llm_model')

    without = client.prepare_tool_list(tools, report_missing: true)
    expect(without[0][:inputSchema][:properties].keys).to eq([:context])
    expect(without[1][:inputSchema][:properties].keys).to eq([:context])
  end

  it 'leaves a composed or referenced schema, and the context argument it owns, alone' do
    composed = { type: 'object', allOf: [{ properties: { context: { type: 'string' } }, required: ['context'] }] }
    expect(client.prepare_tool_list([{ name: 'search', inputSchema: composed }])[0][:inputSchema]).to eq(composed)
    kept = client.prepare_tool_call('search', { context: 'application data' }, input_schema: composed)
    expect(kept.args).to eq(context: 'application data')

    referenced = { type: 'object', :$ref => '#/$defs/payload' }
    expect(client.prepare_tool_list([{ name: 'search', inputSchema: referenced }])[0][:inputSchema]).to eq(referenced)
    expect(client.prepare_tool_call('search', { context: 'application data' }, input_schema: referenced).args)
      .to eq(context: 'application data')
  end

  it 'strips only the context argument it injected when given the tool schema' do
    own = { type: 'object', properties: { context: { type: 'string' } }, required: ['context'] }
    expect(client.prepare_tool_list([{ name: 'search', inputSchema: own }])[0][:inputSchema]).to eq(own)
    kept = client.prepare_tool_call('search', { context: 'application data' }, input_schema: own)
    expect(kept.args).to eq(context: 'application data')
    expect(kept.intent).to eq('application data')

    injected = { type: 'object', properties: { title: { type: 'string' } } }
    stripped = client.prepare_tool_call('add', { title: 'x', context: 'agent intent' }, input_schema: injected)
    expect(stripped.args).to eq(title: 'x')
    expect(stripped.intent).to eq('agent intent')

    expect(client.prepare_tool_call('search', { context: 'application data' }).args).to eq({})
  end
end
