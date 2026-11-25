# frozen_string_literal: true

require_relative 'spec_helper'

class PostHogMcpPersonTool < MCP::Tool
  tool_name 'search_docs'
  input_schema(properties: { fail: { type: 'boolean' } })

  def self.call(fail: false, **)
    raise 'search backend down' if fail

    MCP::Tool::Response.new([{ type: 'text', text: 'found' }])
  end
end

RSpec.describe 'PostHog::MCP person identity' do
  let(:client) { new_test_client }
  let(:server) { MCP::Server.new(name: 'docs-server', version: '1.0.0', tools: [PostHogMcpPersonTool]) }

  before do
    allow(Kernel).to receive(:warn)
    PostHog::MCP.instrument(server, client, identify: lambda { |_request, _extra|
      { distinct_id: 'user-123', properties: { plan: 'pro' } }
    })
  end

  def call_tool(fail:)
    server.handle(rpc(1, 'tools/call', { name: 'search_docs', arguments: { fail: fail } }))
  end

  it 'sends no $identify for an identified call' do
    call_tool(fail: false)

    expect(drain_events(client).map { |event| event[:event] }).not_to include('$identify')
  end

  { '$mcp_tool_call' => false, '$exception' => true }.each do |name, fail|
    it "puts the identity on #{name} as distinct_id and $set" do
      call_tool(fail: fail)

      event = events_named(drain_events(client), name).first
      expect([event[:distinct_id], event[:properties]['$set']]).to eq(['user-123', { 'plan' => 'pro' }])
    end
  end
end
