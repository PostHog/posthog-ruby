# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require_relative 'spec_helper'

class PostHogMcpSpecEchoTool < MCP::Tool
  tool_name 'echo'
  description 'Echoes back'
  meta({ category: 'Utility' })
  input_schema(properties: { message: { type: 'string' } }, required: ['message'])
  class << self
    def call(message:, **)
      MCP::Tool::Response.new([{ type: 'text', text: "Echo: #{message}" }])
    end
  end
end

class PostHogMcpSpecBoomTool < MCP::Tool
  tool_name 'boom'
  description 'Raises'
  class << self
    def call(**)
      raise ArgumentError, 'explode with token phc_123456789012345678901234567890'
    end
  end
end

class PostHogMcpSpecOwnsContextTool < MCP::Tool
  tool_name 'owns_context'
  input_schema(properties: { context: { type: 'string' } })
  class << self
    def call(context: nil, **)
      MCP::Tool::Response.new([{ type: 'text', text: "ctx=#{context}" }])
    end
  end
end

class PostHogMcpSpecStructuredTool < MCP::Tool
  tool_name 'structured'
  input_schema(properties: {})
  output_schema(properties: { total: { type: 'integer' } }, required: ['total'])
  class << self
    def call(**)
      MCP::Tool::Response.new([{ type: 'text', text: 'ok' }], structured_content: { total: 7 })
    end
  end
end

class PostHogMcpSpecErrorResultTool < MCP::Tool
  tool_name 'soft_fail'
  class << self
    def call(**)
      MCP::Tool::Response.new([{ type: 'text', text: 'tool failed badly' }], error: true)
    end
  end
end

class PostHogMcpSpecComposedContextTool < MCP::Tool
  tool_name 'composed'
  input_schema(type: 'object', properties: { message: { type: 'string' } },
               allOf: [{ properties: { context: { type: 'string' } }, required: ['context'] }])
  class << self
    def call(context: nil, **)
      MCP::Tool::Response.new([{ type: 'text', text: "ctx=#{context}" }])
    end
  end
end

class PostHogMcpSpecCaptureTool < MCP::Tool
  tool_name 'capture'
  input_schema(properties: {})
  class << self
    attr_accessor :analytics

    def call(**)
      analytics.capture('in_tool_event')
      MCP::Tool::Response.new([{ type: 'text', text: 'captured' }])
    end
  end
end

RSpec.describe PostHog::MCP do
  let(:client) { new_test_client }
  let(:tools) do
    [PostHogMcpSpecEchoTool, PostHogMcpSpecBoomTool, PostHogMcpSpecOwnsContextTool, PostHogMcpSpecStructuredTool,
     PostHogMcpSpecErrorResultTool]
  end
  let(:server) { MCP::Server.new(name: 'spec-server', version: '9.9.9', tools: tools) }
  let(:client_info) { { name: 'claude-code', version: '1.2.3' } }

  def initialize_request(id = 1, version = '2025-06-18')
    rpc(id, 'initialize', { protocolVersion: version, capabilities: {}, clientInfo: client_info })
  end

  describe '.instrument' do
    it 'returns a handle, is idempotent, and warns about being experimental' do
      expect(PostHog::MCP).to receive(:experimental_notice!).at_least(:once).and_call_original
      expect(Kernel).to receive(:warn).with(a_string_including('experimental')).once
      handle = described_class.instrument(server, client)
      expect(handle).to be_a(PostHog::MCP::Analytics)
      expect(described_class.instrument(server, client)).to be_a(PostHog::MCP::Analytics)
      expect(described_class.tracking_data(server).server_name).to eq('spec-server')
    end

    it 'returns a no-op handle for unsupported servers and when no client is available' do
      allow(Kernel).to receive(:warn)
      allow(PostHog).to receive(:client).and_return(nil) if PostHog.respond_to?(:client)
      expect(described_class.instrument(Object.new, client)).to be_a(PostHog::MCP::NoopAnalytics)
      handle = described_class.instrument(server)
      expect(handle).to be_a(PostHog::MCP::Analytics)
      expect(described_class.tracking_data(server).sink).to be_nil
      server.handle(initialize_request)
      expect(client.queued_messages).to eq(0)
      handle.capture('custom')
    end

    it 'falls back to the posthog-rails facade client when present' do
      allow(Kernel).to receive(:warn)
      facade_client = PostHog::Client.new(api_key: 'phc_facade', test_mode: true)
      # posthog-rails installs `PostHog.client`; emulate it without disturbing a real facade loaded by other specs.
      had_facade = PostHog.respond_to?(:client)
      if had_facade
        allow(PostHog).to receive(:client).and_return(facade_client)
      else
        PostHog.define_singleton_method(:client) { facade_client }
      end
      begin
        described_class.instrument(server)
        expect(described_class.tracking_data(server).sink.client).to equal(facade_client)
      ensure
        PostHog.singleton_class.send(:remove_method, :client) unless had_facade
      end
    end

    it 'leaves a user-provided around_request untouched and still invoked' do
      seen = []
      server.configuration = MCP::Configuration.new(around_request: lambda { |data, &handler|
        seen << data[:method]
        handler.call
      })
      described_class.instrument(server, client)
      server.handle(rpc(1, 'tools/list'))
      expect(seen).to eq(['tools/list'])
      expect(drain_events(client).map { |e| e[:event] }).to include('$mcp_tools_list')
    end
  end

  describe 'end to end over Server#handle' do
    before { allow(Kernel).to receive(:warn) }

    it 'captures initialize, tools/list and a successful tool call with $lib override' do
      described_class.instrument(server, client)
      response = server.handle(initialize_request)
      expect(response[:result][:protocolVersion]).to eq('2025-06-18')
      list = server.handle(rpc(2, 'tools/list'))
      echo = list[:result][:tools].find { |t| t[:name] == 'echo' }
      expect(echo[:inputSchema][:properties].keys).to eq(%i[message context])
      expect(echo[:inputSchema][:required]).to eq(%w[message context])
      expect(PostHogMcpSpecEchoTool.input_schema.to_h[:properties].keys).to eq([:message])

      arguments = { message: 'hi', context: 'Echoing for jane@example.com' }
      result = server.handle(rpc(3, 'tools/call', { name: 'echo', arguments: arguments }))
      expect(result[:result][:content]).to eq([{ type: 'text', text: 'Echo: hi' }])

      events = drain_events(client)
      expect(events.map { |e| e[:event] }).to eq(['$mcp_initialize', '$mcp_tools_list', '$mcp_tool_call'])
      init = events[0]
      expect(init[:properties]).to include('$mcp_client_name' => 'claude-code', '$mcp_client_version' => '1.2.3',
                                           '$mcp_protocol_version' => '2025-06-18', '$mcp_server_name' => 'spec-server',
                                           '$mcp_server_version' => '9.9.9', '$lib' => 'posthog-ruby-mcp',
                                           '$lib_version' => PostHog::VERSION, '$process_person_profile' => false)
      expect(init[:distinct_id]).to eq(init[:properties]['$session_id'])
      expect(init[:properties]['$session_id']).to match(/\Ases_/)

      listing = events[1][:properties]
      expect(listing['$mcp_listed_tool_names']).to eq(%w[echo boom owns_context structured soft_fail])
      expect(listing['$mcp_is_error']).to be(false)

      call = events[2][:properties]
      expect(call).to include('$mcp_tool_name' => 'echo', '$mcp_resource_name' => 'echo',
                              '$mcp_tool_description' => 'Echoes back', '$mcp_tool_category' => 'Utility',
                              '$mcp_intent' => 'Echoing for [redacted]',
                              '$mcp_intent_source' => 'context_parameter', '$mcp_is_error' => false,
                              '$mcp_client_name' => 'claude-code', '$mcp_source' => 'posthog_mcp_analytics')
      expect(call['$mcp_parameters']['request']['params']['arguments']).to eq('message' => 'hi')
      expect(call['$mcp_response']['content'][0]['text']).to eq('Echo: hi')
      expect(call['$mcp_duration_ms']).to be_a(Float)
      expect(events.map { |e| e[:properties]['$session_id'] }.uniq.length).to eq(1)
    end

    it 'strips the injected context before the tool sees it but keeps a tool-owned context' do
      described_class.instrument(server, client)
      result = server.handle(rpc(1, 'tools/call', { name: 'owns_context', arguments: { context: 'mine' } }))
      expect(result[:result][:content][0][:text]).to eq('ctx=mine')
      list = server.handle(rpc(2, 'tools/list'))
      owns = list[:result][:tools].find { |t| t[:name] == 'owns_context' }
      expect(owns[:inputSchema][:required]).to be_nil
    end

    it 'records raised tool errors with unwrapped scalars and an $exception sibling, then re-raises to the client' do
      described_class.instrument(server, client)
      response = server.handle(rpc(1, 'tools/call', { name: 'boom', arguments: { context: 'break it' } }))
      expect(response[:error][:code]).to eq(-32_603)
      events = drain_events(client)
      expect(events.map { |e| e[:event] }).to eq(['$mcp_initialize', '$mcp_tool_call', '$exception'])
      call = events[1][:properties]
      expect(call).to include('$mcp_is_error' => true, '$mcp_error_type' => 'ArgumentError',
                              '$mcp_error_message' => 'explode with token [redacted]')
      expect(call).not_to have_key('$mcp_response')
      sibling = events[2][:properties]
      expect(sibling['$exception_list'].map { |e| e['type'] }).to eq(%w[MCP::Server::RequestHandlerError ArgumentError])
      expect(sibling).to include('$mcp_tool_name' => 'boom', '$exception_level' => 'error')
      expect(sibling).not_to have_key('$mcp_source')
    end

    it 'treats isError results as errors and honours enable_exception_autocapture: false' do
      described_class.instrument(server, client, enable_exception_autocapture: false)
      server.handle(rpc(1, 'tools/call', { name: 'soft_fail', arguments: {} }))
      events = drain_events(client)
      expect(events.map { |e| e[:event] }).to eq(['$mcp_initialize', '$mcp_tool_call'])
      expect(events[1][:properties]).to include('$mcp_is_error' => true, '$mcp_error_type' => 'Error',
                                                '$mcp_error_message' => 'tool failed badly')
    end

    it 'captures prompts and resources events' do
      server.define_prompt(name: 'greet', description: 'g', arguments: []) do |_args, **|
        MCP::Prompt::Result.new(description: 'x', messages: [])
      end
      server.define_resource(uri: 'file:///readme', name: 'readme', mime_type: 'text/plain') do
        [{ uri: 'file:///readme', text: 'hello' }]
      end
      described_class.instrument(server, client)
      server.handle(rpc(1, 'prompts/list'))
      server.handle(rpc(2, 'prompts/get', { name: 'greet', arguments: {} }))
      server.handle(rpc(3, 'resources/list'))
      server.handle(rpc(4, 'resources/read', { uri: 'file:///readme' }))
      events = drain_events(client)
      names = events.map { |e| e[:event] }
      expect(names).to eq(['$mcp_initialize', '$mcp_prompts_list', '$mcp_prompt_get', '$mcp_resources_list',
                           '$mcp_resource_read'])
      expect(events[2][:properties]['$mcp_resource_name']).to eq('greet')
      expect(events[2][:properties]).not_to have_key('$mcp_tool_name')
      expect(events[4][:properties]['$mcp_resource_name']).to eq('file:///readme')
      expect(events[4][:properties]['$mcp_response']['contents'][0]['text']).to eq('hello')
    end

    it 'redacts binary prompt messages and resource blobs on the way out' do
      server.define_prompt(name: 'picture', description: 'p', arguments: []) do |_args, **|
        MCP::Prompt::Result.new(description: 'x', messages: [
                                  MCP::Prompt::Message.new(
                                    role: 'user',
                                    content: MCP::Content::Image.new('c2Vuc2l0aXZl', 'image/png')
                                  )
                                ])
      end
      server.define_resource(uri: 'file:///data.bin', name: 'data', mime_type: 'application/octet-stream') do
        [{ uri: 'file:///data.bin', mimeType: 'application/octet-stream', blob: 'c2Vuc2l0aXZl' }]
      end
      described_class.instrument(server, client)
      server.handle(rpc(1, 'prompts/get', { name: 'picture', arguments: {} }))
      server.handle(rpc(2, 'resources/read', { uri: 'file:///data.bin' }))
      events = drain_events(client)
      prompt = events.find { |e| e[:event] == '$mcp_prompt_get' }
      read = events.find { |e| e[:event] == '$mcp_resource_read' }
      expect(prompt[:properties]['$mcp_response']['messages'][0]['content'])
        .to eq('type' => 'text', 'text' => '[image content redacted - not supported by PostHog MCP analytics]')
      expect(read[:properties]['$mcp_response']['contents'][0]['blob'])
        .to eq('[binary resource content redacted - not supported by PostHog MCP analytics]')
      expect(JSON.generate(events)).not_to include('c2Vuc2l0aXZl')
    end

    it 'leaves a composed schema and the context argument it owns alone, listed or not' do
      composed = MCP::Server.new(name: 'spec-server', version: '9.9.9', tools: [PostHogMcpSpecComposedContextTool])
      described_class.instrument(composed, client)
      # Called before any tools/list, so ownership is decided from the schema alone.
      first = composed.handle(rpc(1, 'tools/call', { name: 'composed', arguments: { context: 'why' } }))
      expect(first[:result][:content][0][:text]).to eq('ctx=why')

      listed = composed.handle(rpc(2, 'tools/list'))[:result][:tools][0][:inputSchema]
      expect(listed[:properties].keys).to eq([:message])
      expect(listed[:allOf]).to eq([{ properties: { context: { type: 'string' } }, required: ['context'] }])

      second = composed.handle(rpc(3, 'tools/call', { name: 'composed', arguments: { context: 'why' } }))
      expect(second[:result][:content][0][:text]).to eq('ctx=why')
      calls = drain_events(client).select { |e| e[:event] == '$mcp_tool_call' }
      expect(calls.map { |c| c[:properties]['$mcp_intent'] }).to eq(%w[why why])
    end

    it 'flags an empty tools/list as an error' do
      empty_server = MCP::Server.new(name: 'empty', tools: [])
      described_class.instrument(empty_server, client)
      empty_server.handle(rpc(1, 'tools/list'))
      events = drain_events(client)
      listing = events.find { |e| e[:event] == '$mcp_tools_list' }[:properties]
      expect(listing['$mcp_is_error']).to be(true)
      expect(listing['$mcp_error_message']).to eq('tools/list returned no tools')
      expect(events.map { |e| e[:event] }).to include('$exception')
    end
  end

  describe 'identify, event_properties and before_send' do
    before { allow(Kernel).to receive(:warn) }

    it 'identifies once per session, sets $set/$groups and turns person processing on' do
      calls = 0
      identify = lambda do |_request, _extra|
        calls += 1
        { distinct_id: 'user-1', properties: { name: 'Alice' }, groups: { organization: 'org_123' } }
      end
      described_class.instrument(server, client, identify: identify, event_properties: lambda { |_r, _e|
        { env: 'production' }
      })
      server.handle(initialize_request)
      3.times { |i| server.handle(rpc(i + 2, 'tools/call', { name: 'echo', arguments: { message: 'x' } })) }
      events = drain_events(client)
      expect(events.count { |e| e[:event] == '$identify' }).to eq(1)
      expect(calls).to eq(4)
      call = events.find { |e| e[:event] == '$mcp_tool_call' }
      expect(call[:distinct_id]).to eq('user-1')
      expect(call[:properties]).to include('$set' => { 'name' => 'Alice' }, '$groups' => { 'organization' => 'org_123' },
                                           'env' => 'production')
      expect(call[:properties]).not_to have_key('$process_person_profile')
      identify_event = events.find { |e| e[:event] == '$identify' }
      expect(identify_event[:properties]['$mcp_resource_name']).to eq('Unknown')
    end

    it 'runs before_send per payload, dropping and mutating' do
      before_send = lambda do |payload|
        next nil if payload['event'] == '$exception'

        payload['properties'].delete('$mcp_intent')
        payload
      end
      described_class.instrument(server, client, before_send: before_send)
      server.handle(rpc(1, 'tools/call', { name: 'boom', arguments: { context: 'secret intent' } }))
      events = drain_events(client)
      expect(events.map { |e| e[:event] }).to eq(['$mcp_initialize', '$mcp_tool_call'])
      expect(events[1][:properties]).not_to have_key('$mcp_intent')
    end

    it 'never lets analytics failures reach the tool' do
      described_class.instrument(server, client, identify: ->(_r, _e) { raise 'identify exploded' },
                                                 event_properties: ->(_r, _e) { raise 'props exploded' },
                                                 intent_fallback: ->(_r, _e) { raise 'intent exploded' })
      result = server.handle(rpc(1, 'tools/call', { name: 'echo', arguments: { message: 'hi' } }))
      expect(result[:result][:content][0][:text]).to eq('Echo: hi')
      expect(drain_events(client).map { |e| e[:event] }).to include('$mcp_tool_call')
    end

    it 'uses intent_fallback when no context arrives' do
      fallback = ->(request, _e) { " Invoking #{request[:params][:name]} " }
      described_class.instrument(server, client, intent_fallback: fallback)
      server.handle(rpc(1, 'tools/call', { name: 'echo', arguments: { message: 'hi' } }))
      call = drain_events(client).find { |e| e[:event] == '$mcp_tool_call' }
      expect(call[:properties]).to include('$mcp_intent' => 'Invoking echo', '$mcp_intent_source' => 'inferred')
    end
  end

  describe 'conversation ids, get_more_tools and llm_model' do
    before { allow(Kernel).to receive(:warn) }

    it 'mints, prompts back, mirrors into structuredContent and anchors the session on an echo' do
      described_class.instrument(server, client, enable_conversation_id: true)
      list = server.handle(rpc(1, 'tools/list'))
      structured = list[:result][:tools].find { |t| t[:name] == 'structured' }
      expect(structured[:inputSchema][:properties]).to have_key(:conversation_id)
      expect(structured[:outputSchema][:properties]).to have_key(:_mcp_instructions)
      expect(structured[:inputSchema][:required]).to eq(['context'])

      first = server.handle(rpc(2, 'tools/call', { name: 'echo', arguments: { message: 'hi', context: 'c' } }))
      prompt_back = JSON.parse(first[:result][:content][1][:text])
      handle = prompt_back['conversation_id']
      expect(handle).to match(PostHog::MCP::ConversationId::MINTED_CONVERSATION_ID)

      arguments = { context: 'c', conversation_id: handle.upcase }
      second = server.handle(rpc(3, 'tools/call', { name: 'structured', arguments: arguments }))
      expect(second[:result][:structuredContent]).to eq(total: 7, _mcp_instructions: { 'conversation_id' => handle })
      expect(second[:result][:content].length).to eq(1)

      events = drain_events(client)
      calls = events.select { |e| e[:event] == '$mcp_tool_call' }
      expect(calls.map { |c| c[:properties]['$mcp_conversation_id'] }).to eq([handle, handle])
      expected_session = PostHog::MCP.derive_session_id_from_conversation(handle)
      expect(calls.map { |c| c[:properties]['$session_id'] }.uniq).to eq([expected_session])
      expect(calls[0][:properties]['$mcp_parameters']['request']['params']['arguments']).to eq('message' => 'hi')
    end

    it 'drops a minted handle when the call raises so sessions do not orphan' do
      described_class.instrument(server, client, enable_conversation_id: true)
      2.times { |i| server.handle(rpc(i + 1, 'tools/call', { name: 'boom', arguments: { context: 'c' } })) }
      events = drain_events(client)
      calls = events.select { |e| e[:event] == '$mcp_tool_call' }
      expect(calls.map { |c| c[:properties].key?('$mcp_conversation_id') }).to eq([false, false])
      expect(events.map { |e| e[:properties]['$session_id'] }.uniq.length).to eq(1)
    end

    it 'keeps the conversation handle out of the error message so failures still group' do
      described_class.instrument(server, client, enable_conversation_id: true)
      2.times { |i| server.handle(rpc(i + 1, 'tools/call', { name: 'soft_fail', arguments: { context: 'c' } })) }
      events = drain_events(client)
      calls = events.select { |e| e[:event] == '$mcp_tool_call' }
      expect(calls.map { |c| c[:properties]['$mcp_error_message'] }).to eq(['tool failed badly'] * 2)
      expect(events.select { |e| e[:event] == '$exception' }
                   .map { |e| e[:properties]['$exception_list'][0]['value'] }).to eq(['tool failed badly'] * 2)
      # The handle still reaches the agent on the delivered result.
      expect(calls[0][:properties]['$mcp_response']['content'].length).to eq(2)
      expect(calls[0][:properties]['$mcp_conversation_id']).to be_a(String)
    end

    it 'advertises and intercepts get_more_tools as $mcp_missing_capability' do
      described_class.instrument(server, client, report_missing: true)
      list = server.handle(rpc(1, 'tools/list'))
      virtual = list[:result][:tools].last
      expect(virtual[:name]).to eq('get_more_tools')
      expect(virtual[:inputSchema][:properties].keys).to eq([:context])
      result = server.handle(rpc(2, 'tools/call',
                                 { name: 'get_more_tools', arguments: { context: 'need csv export' } }))
      expect(result[:result][:content][0][:text]).to include('Unfortunately')
      events = drain_events(client)
      listing = events.find { |e| e[:event] == '$mcp_tools_list' }
      expect(listing[:properties]['$mcp_listed_tool_names']).to include('get_more_tools')
      missing = events.find { |e| e[:event] == '$mcp_missing_capability' }
      expect(missing[:properties]).to include('$mcp_intent' => 'need csv export',
                                              '$mcp_intent_source' => 'context_parameter',
                                              '$mcp_resource_name' => 'get_more_tools')
      expect(missing[:properties]).not_to have_key('$mcp_tool_name')
      expect(events.none? { |e| e[:event] == '$mcp_tool_call' }).to be(true)
    end

    it 'lets the gem validate get_more_tools arguments and still records the missing capability' do
      described_class.instrument(server, client, report_missing: true)
      result = server.handle(rpc(2, 'tools/call', { name: 'get_more_tools', arguments: {} }))
      expect(result[:result][:isError]).to be(true)
      expect(result[:result][:content][0][:text]).to include('Missing required arguments: context')
      events = drain_events(client)
      missing = events.find { |e| e[:event] == '$mcp_missing_capability' }
      expect(missing[:properties]['$mcp_resource_name']).to eq('get_more_tools')
      expect(missing[:properties]).not_to have_key('$mcp_intent')
      expect(events.none? { |e| e[:event] == '$mcp_tool_call' }).to be(true)
    end

    it 'leaves an application tool named get_more_tools alone' do
      own = MCP::Tool.define(name: 'get_more_tools', input_schema: { properties: {} }) do |**|
        MCP::Tool::Response.new([{ type: 'text', text: 'mine' }])
      end
      server = MCP::Server.new(name: 'spec-server', version: '9.9.9', tools: [PostHogMcpSpecEchoTool, own])
      described_class.instrument(server, client, report_missing: true)
      expect(server.tools['get_more_tools']).to equal(own)
      result = server.handle(rpc(2, 'tools/call', { name: 'get_more_tools', arguments: { context: 'why' } }))
      expect(result[:result][:content][0][:text]).to eq('mine')
      events = drain_events(client)
      expect(events.map { |e| e[:event] }).to include('$mcp_tool_call')
      expect(events.none? { |e| e[:event] == '$mcp_missing_capability' }).to be(true)
    end

    it 'advertises llm_model on get_more_tools and records it on the missing-capability event' do
      described_class.instrument(server, client, report_missing: true, capture_model: true)
      list = server.handle(rpc(1, 'tools/list'))
      virtual = list[:result][:tools].find { |t| t[:name] == 'get_more_tools' }
      expect(virtual[:inputSchema][:properties].keys).to contain_exactly(:context, :llm_model)
      expect(virtual[:inputSchema][:properties].keys).not_to include(:conversation_id)
      expect(virtual[:inputSchema][:required]).to contain_exactly('context', 'llm_model')
      result = server.handle(rpc(2, 'tools/call', { name: 'get_more_tools',
                                                    arguments: { context: 'need csv export',
                                                                 llm_model: ' claude-opus-4-8 ' } }))
      expect(result[:result][:content][0][:text]).to include('Unfortunately')
      missing = drain_events(client).find { |e| e[:event] == '$mcp_missing_capability' }
      expect(missing[:properties]).to include('$mcp_llm_model' => 'claude-opus-4-8',
                                              '$mcp_llm_model_source' => 'self_reported')
    end

    it 'captures llm_model from the injected argument or client metadata' do
      described_class.instrument(server, client, capture_model: true)
      server.handle(rpc(1, 'tools/call',
                        { name: 'echo', arguments: { message: 'hi', llm_model: ' claude-opus-4-8 ' } }))
      server.handle(rpc(2, 'tools/call', { name: 'echo', arguments: { message: 'hi', llm_model: 'unknown' } }))
      server.handle(rpc(3, 'tools/call', { name: 'echo', arguments: { message: 'hi', llm_model: 'self' },
                                           _meta: { 'x-codex-turn-metadata' => { 'model' => 'gpt-5.6-sol' } } }))
      calls = drain_events(client).select { |e| e[:event] == '$mcp_tool_call' }.map { |e| e[:properties] }
      expect(calls[0]).to include('$mcp_llm_model' => 'claude-opus-4-8', '$mcp_llm_model_source' => 'self_reported')
      expect(calls[1]).not_to have_key('$mcp_llm_model')
      expect(calls[2]).to include('$mcp_llm_model' => 'gpt-5.6-sol', '$mcp_llm_model_source' => 'client_metadata')
    end
  end

  describe 'payload size' do
    it 'keeps every captured message under the core client per-message limit so it is not dropped' do
      allow(Kernel).to receive(:warn)
      server.define_tool(name: 'huge', input_schema: { properties: {} }) do |**|
        MCP::Tool::Response.new([{ type: 'text', text: 'lorem ipsum ' * 5000 }])
      end
      described_class.instrument(server, client)
      server.handle(rpc(1, 'tools/call', { name: 'huge', arguments: { context: 'c' * 5000 } }))
      events = drain_events(client)
      call = events.find { |e| e[:event] == '$mcp_tool_call' }
      expect(call[:properties]['$mcp_response']['content'][0]['text']).to end_with('...')
      events.each do |message|
        expect(JSON.generate(message).bytesize).to be < PostHog::Defaults::Message::MAX_BYTES
      end
    end
  end

  describe 'custom events' do
    it 'anchors an in-tool event on the echoed conversation and the identified person' do
      allow(Kernel).to receive(:warn)
      capture_server = MCP::Server.new(name: 'spec-server', version: '9.9.9', tools: [PostHogMcpSpecCaptureTool])
      PostHogMcpSpecCaptureTool.analytics = described_class.instrument(
        capture_server, client, enable_conversation_id: true, identify: { distinct_id: 'user-1' }
      )
      conversation = '019fd2b0-1111-7111-8111-111111111111'
      capture_server.handle(rpc(1, 'tools/call', { name: 'capture',
                                                   arguments: { context: 'c', conversation_id: conversation } }))
      events = drain_events(client)
      custom = events.find { |e| e[:event] == 'in_tool_event' }
      call = events.find { |e| e[:event] == '$mcp_tool_call' }
      expect(custom[:properties]['$session_id'])
        .to eq(described_class.derive_session_id_from_conversation(conversation))
      expect(custom[:properties]['$session_id']).to eq(call[:properties]['$session_id'])
      expect(custom[:distinct_id]).to eq('user-1')
      expect(custom[:distinct_id]).to eq(call[:distinct_id])
    end

    it 'gives a capture that lost its request scope a standalone session on an HTTP server' do
      allow(Kernel).to receive(:warn)
      logs = []
      handle = described_class.instrument(server, client, logger: ->(message) { logs << message })
      server.handle(initialize_request)
      data = described_class.tracking_data(server)
      data.http_transport_seen = true # a request has arrived over HTTP
      handle.capture('detached_event')
      custom = drain_events(client).find { |e| e[:event] == 'detached_event' }
      expect(custom[:properties]['$session_id']).to start_with('ses_')
      expect(custom[:properties]['$session_id']).not_to eq(data.session_id)
      expect(logs).to include(a_string_including('without the scope of the request'))
    end

    it 'sends custom events verbatim on the current session' do
      allow(Kernel).to receive(:warn)
      handle = described_class.instrument(server, client)
      server.handle(initialize_request)
      handle.capture('feedback_submitted', { rating: 5 })
      expect { handle.capture('') }.to raise_error(ArgumentError)
      events = drain_events(client)
      custom = events.last
      expect(custom[:event]).to eq('feedback_submitted')
      expect(custom[:properties]).to include('rating' => 5, '$mcp_server_name' => 'spec-server')
      expect(custom[:properties]['$session_id']).to eq(events.first[:properties]['$session_id'])
    end
  end

  describe 'concurrency' do
    it 'does not cross-attribute concurrent requests' do
      allow(Kernel).to receive(:warn)
      described_class.instrument(server, client)
      threads = 8.times.map do |i|
        Thread.new do
          server.handle(rpc(i, 'tools/call', { name: 'echo', arguments: { message: "m#{i}", context: "intent #{i}" } }))
        end
      end
      threads.each(&:join)
      calls = drain_events(client).select { |e| e[:event] == '$mcp_tool_call' }
      expect(calls.length).to eq(8)
      calls.each do |call|
        message = call[:properties]['$mcp_parameters']['request']['params']['arguments']['message']
        expect(call[:properties]['$mcp_intent']).to eq("intent #{message.delete_prefix('m')}")
        expect(call[:properties]['$mcp_response']['content'][0]['text']).to eq("Echo: #{message}")
      end
    end
  end
end
# rubocop:enable Layout/LineLength
