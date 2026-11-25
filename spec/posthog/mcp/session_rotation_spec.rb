# frozen_string_literal: true

require_relative 'spec_helper'

class PostHogMcpRotationTool < MCP::Tool
  tool_name 'search_docs'
  input_schema(properties: { query: { type: 'string' } })
  class << self
    attr_accessor :analytics, :during_call

    def call(**)
      during_call&.call
      analytics&.capture('docs_searched')
      MCP::Tool::Response.new([{ type: 'text', text: 'found' }])
    end
  end
end

RSpec.describe 'PostHog::MCP one-client connection sessions' do
  let(:client) { new_test_client }
  let(:server) { MCP::Server.new(name: 'stdio-server', version: '1.0.0', tools: [PostHogMcpRotationTool]) }
  let(:start) { Time.now }

  before do
    PostHogMcpRotationTool.analytics = PostHog::MCP.instrument(server, client, enable_conversation_id: false)
    PostHogMcpRotationTool.during_call = nil
  end

  after { PostHogMcpRotationTool.during_call = nil }

  def at(minute)
    allow(Time).to receive(:now).and_return(start + (minute * 60))
  end

  def call_tool(id, meta: nil)
    params = { name: 'search_docs', arguments: { query: 'flags' } }
    params[:_meta] = meta if meta
    server.handle(rpc(id, 'tools/call', params))
  end

  def sessions_of(name)
    events_named(drain_events(client), name).map { |event| event[:properties]['$session_id'] }
  end

  # Each step is [minute, request]; the expectation says which tool calls share a session.
  {
    'keeps the session while calls come less than 30 minutes apart' => [[[0, :call], [29, :call]], [0, 0]],
    'rolls the session over at exactly 30 idle minutes' => [[[0, :call], [30, :call]], [0, 1]],
    'counts idle time from tool calls only, not listings' => [[[0, :call], [20, :list], [35, :call]], [0, 1]],
    'counts idle time from when the previous call ended' => [[[0, :long_call], [41, :call]], [0, 0]]
  }.each do |behavior, (steps, groups)|
    it behavior do
      steps.each_with_index do |(minute, request), index|
        at(minute)
        case request
        when :call then call_tool(index + 1)
        when :list then server.handle(rpc(index + 1, 'tools/list'))
        when :long_call
          PostHogMcpRotationTool.during_call = -> { at(minute + 40) }
          call_tool(index + 1)
          PostHogMcpRotationTool.during_call = nil
        end
      end

      sessions = sessions_of('$mcp_tool_call')
      expect(sessions.map { |session| sessions.uniq.index(session) }).to eq(groups)
    end
  end

  it 'keeps the session a call arrived with for every event of a call that outlasts the idle limit' do
    at(0)
    PostHogMcpRotationTool.during_call = -> { at(40) }
    call_tool(1)

    events = drain_events(client)
    expect(events.map { |event| event[:properties]['$session_id'] }.uniq.size).to eq(1)
  end

  it 'gives a custom event captured before any request the connection\'s session' do
    PostHogMcpRotationTool.analytics.capture('server_started')
    call_tool(1)

    events = drain_events(client)
    started = events_named(events, 'server_started').first[:properties]
    expect(started.values_at('$session_id', '$mcp_session_source'))
      .to eq([events_named(events, '$mcp_tool_call').first[:properties]['$session_id'], 'generated'])
  end
end
