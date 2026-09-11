# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::EventBuilder do
  let(:base) do
    {
      'id' => 'evt_test123', 'session_id' => 'ses_session456', 'event_type' => 'mcp:tools/call',
      'timestamp' => Time.utc(2025, 1, 15, 10), 'resource_name' => 'get_weather',
      'server_name' => 'weather-server', 'server_version' => '1.0.0',
      'client_name' => 'claude-desktop', 'client_version' => '2.0.0', 'duration' => 150, 'is_error' => false
    }
  end

  def error_for(message, type)
    { '$exception_list' => [{ 'type' => type, 'value' => message, 'mechanism' => { 'type' => 'generic', 'handled' => true } }],
      '$exception_level' => 'error' }
  end

  it 'builds the default tool call payload exactly' do
    events = described_class.build(base)
    expect(events.length).to eq(1)
    event = events[0]
    expect(event['event']).to eq('$mcp_tool_call')
    expect(event['distinct_id']).to eq('ses_session456')
    expect(event['timestamp']).to eq(Time.utc(2025, 1, 15, 10))
    expect(event['properties']).to eq(
      '$session_id' => 'ses_session456', '$mcp_source' => 'posthog_mcp_analytics', '$mcp_tool_name' => 'get_weather',
      '$mcp_resource_name' => 'get_weather', '$mcp_duration_ms' => 150, '$mcp_server_name' => 'weather-server',
      '$mcp_server_version' => '1.0.0', '$mcp_client_name' => 'claude-desktop', '$mcp_client_version' => '2.0.0',
      '$mcp_is_error' => false, '$process_person_profile' => false
    )
  end

  it 'adds identity, intent, parameters and response' do
    event = described_class.build(base.merge(
                                    'identify_actor_given_id' => 'user_abc123', 'duration' => 250, 'parameters' => { 'city' => 'London' },
                                    'response' => { 'temp' => 15 }, 'user_intent' => 'Check the weather in London',
                                    'user_intent_source' => 'context_parameter', 'identify_actor_data' => { 'name' => 'Alice', 'plan' => 'pro' },
                                    'groups' => { 'organization' => 'org_123' }, 'llm_model' => 'claude-opus-4-8', 'llm_model_source' => 'self_reported'
                                  ))[0]
    props = event['properties']
    expect(event['distinct_id']).to eq('user_abc123')
    expect(props).to include('$mcp_duration_ms' => 250, '$mcp_intent' => 'Check the weather in London',
                             '$mcp_intent_source' => 'context_parameter', '$mcp_parameters' => { 'city' => 'London' },
                             '$mcp_response' => { 'temp' => 15 }, '$set' => { 'name' => 'Alice', 'plan' => 'pro' },
                             '$groups' => { 'organization' => 'org_123' }, '$mcp_llm_model' => 'claude-opus-4-8',
                             '$mcp_llm_model_source' => 'self_reported')
    expect(props).not_to have_key('$process_person_profile')
  end

  it 'fans out an $exception sibling with the narrower property set' do
    events = described_class.build(base.merge('is_error' => true, 'error' => error_for('Connection timeout', 'TimeoutError'),
                                              'protocol_version' => '2025-06-18', 'tool_description' => 'Fetches weather',
                                              'tool_category' => 'Logs', 'groups' => { 'organization' => 'org_123' },
                                              'properties' => { 'deployment' => 'prod' }, 'parameters' => { 'a' => 1 }))
    expect(events.length).to eq(2)
    primary = events[0]['properties']
    expect(primary).to include('$mcp_is_error' => true, '$mcp_error_type' => 'TimeoutError',
                               '$mcp_error_message' => 'Connection timeout', '$mcp_tool_description' => 'Fetches weather',
                               '$mcp_tool_category' => 'Logs')
    sibling = events[1]
    expect(sibling['event']).to eq('$exception')
    expect(sibling['distinct_id']).to eq('ses_session456')
    expect(sibling['properties']).to eq(
      '$session_id' => 'ses_session456', '$process_person_profile' => false, '$groups' => { 'organization' => 'org_123' },
      '$exception_list' => [{ 'type' => 'TimeoutError', 'value' => 'Connection timeout',
                              'mechanism' => { 'type' => 'generic', 'handled' => true } }],
      '$exception_level' => 'error', '$mcp_resource_name' => 'get_weather', '$mcp_tool_name' => 'get_weather',
      '$mcp_tool_description' => 'Fetches weather', '$mcp_tool_category' => 'Logs', '$mcp_server_name' => 'weather-server',
      '$mcp_server_version' => '1.0.0', '$mcp_client_name' => 'claude-desktop', '$mcp_client_version' => '2.0.0',
      '$mcp_protocol_version' => '2025-06-18', 'deployment' => 'prod'
    )
  end

  it 'honours the exception autocapture toggle and the error matrix' do
    errored = base.merge('is_error' => true, 'error' => error_for('Connection timeout', 'TimeoutError'))
    expect(described_class.build(errored, enable_exception_autocapture: false).length).to eq(1)

    props = described_class.build(errored.merge('error_type' => 'rate_limited'))[0]['properties']
    expect(props).to include('$mcp_error_type' => 'rate_limited', '$mcp_error_message' => 'Connection timeout')

    props = described_class.build(base.merge('is_error' => true, 'error_type' => 'validation'))[0]['properties']
    expect(props).to include('$mcp_error_type' => 'validation')
    expect(props).not_to have_key('$mcp_error_message')

    props = described_class.build(base)[0]['properties']
    expect(props).not_to have_key('$mcp_error_type')
    expect(props).not_to have_key('$mcp_error_message')
  end

  it 'steps past the Ruby dispatch wrapper when picking error scalars' do
    error = { '$exception_list' => [
      { 'type' => 'MCP::Server::RequestHandlerError', 'value' => 'Internal error calling tool boom' },
      { 'type' => 'ArgumentError', 'value' => 'explode' }
    ] }
    props = described_class.build(base.merge('is_error' => true, 'error' => error))[0]['properties']
    expect(props).to include('$mcp_error_type' => 'ArgumentError', '$mcp_error_message' => 'explode')
  end

  it 'scopes tool-only properties and listed tool names by event type' do
    props = described_class.build(base.merge('event_type' => 'mcp:resources/read', 'resource_name' => 'my_resource',
                                             'tool_description' => 'd', 'listed_tool_names' => ['ignored']))[0]['properties']
    expect(props['$mcp_resource_name']).to eq('my_resource')
    expect(props).not_to have_key('$mcp_tool_name')
    expect(props).not_to have_key('$mcp_tool_description')
    expect(props).not_to have_key('$mcp_listed_tool_names')

    props = described_class.build(base.merge('event_type' => 'mcp:tools/list', 'resource_name' => nil,
                                             'listed_tool_names' => %w[get_weather list_alerts]))[0]['properties']
    expect(props['$mcp_listed_tool_names']).to eq(%w[get_weather list_alerts])
    props = described_class.build(base.merge('event_type' => 'mcp:tools/list',
                                             'listed_tool_names' => []))[0]['properties']
    expect(props).not_to have_key('$mcp_listed_tool_names')
  end

  it 'maps every event type and sends custom names verbatim' do
    {
      'posthog:custom' => '$mcp_custom', 'posthog:identify' => '$identify', 'mcp:tools/call' => '$mcp_tool_call',
      'mcp:tools/list' => '$mcp_tools_list', 'mcp:initialize' => '$mcp_initialize',
      'mcp:resources/read' => '$mcp_resource_read', 'mcp:resources/list' => '$mcp_resources_list',
      'mcp:prompts/get' => '$mcp_prompt_get', 'mcp:prompts/list' => '$mcp_prompts_list',
      'mcp:missing_capability' => '$mcp_missing_capability'
    }.each do |type, name|
      expect(described_class.build({ 'event_type' => type })[0]['event']).to eq(name)
    end
    event = described_class.build({ 'event_type' => 'posthog:custom', 'event_name' => 'feedback_submitted',
                                    'properties' => { 'rating' => 5 } })[0]
    expect(event['event']).to eq('feedback_submitted')
    expect(event['properties']['rating']).to eq(5)
    expect(event['distinct_id']).to eq('anonymous')
  end
end
# rubocop:enable Layout/LineLength
