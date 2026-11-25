# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe 'PostHog::MCP get_more_tools sessions' do
  let(:client) { new_test_client }
  let(:server) { MCP::Server.new(name: 'docs-server', version: '1.0.0', tools: []) }
  let(:handle) { '0190f0e8-7a6b-7c3d-9e4f-5a6b7c8d9e0f' }

  before { allow(Kernel).to receive(:warn) }

  def report(arguments)
    server.handle(rpc(2, 'tools/call',
                      { name: 'get_more_tools', arguments: { context: 'need csv export' }.merge(arguments) }))
  end

  def listed_arguments
    server.handle(rpc(1, 'tools/list'))[:result][:tools].find do |tool|
      tool[:name] == 'get_more_tools'
    end[:inputSchema][:properties].keys
  end

  def missing_capability
    events_named(drain_events(client), '$mcp_missing_capability').first[:properties]
  end

  {
    'on' => [true, true],
    'off' => [false, false]
  }.each do |anchoring, (enabled, advertised)|
    it "advertises conversation_id on get_more_tools with anchoring #{anchoring}" do
      PostHog::MCP.instrument(server, client, report_missing: true, capture_model: false,
                                              enable_conversation_id: enabled)

      expect(listed_arguments.include?(:conversation_id)).to eq(advertised)
    end
  end

  it 'mints a handle for a report that carries none, and files the report under it' do
    PostHog::MCP.instrument(server, client, report_missing: true)
    texts = report({})[:result][:content].map { |block| block[:text] }

    minted = JSON.parse(texts.last)['conversation_id']
    expect(minted).to match(/\A\h{8}-\h{4}-7\h{3}-/)
    expect(missing_capability.values_at('$mcp_conversation_id', '$session_id', '$mcp_session_source'))
      .to eq([minted, PostHog::MCP.derive_session_id_from_conversation(minted), 'conversation'])
  end

  it 'sends the report without $mcp_parameters' do
    PostHog::MCP.instrument(server, client, report_missing: true)
    report({ conversation_id: handle })

    expect(missing_capability).not_to have_key('$mcp_parameters')
  end

  it 'files a report under the handle the agent echoes, and mints none' do
    PostHog::MCP.instrument(server, client, report_missing: true)
    texts = report({ conversation_id: handle })[:result][:content].map { |block| block[:text] }

    expect(texts.size).to eq(1)
    expect(missing_capability.values_at('$mcp_conversation_id', '$session_id'))
      .to eq([handle, PostHog::MCP.derive_session_id_from_conversation(handle)])
  end
end
