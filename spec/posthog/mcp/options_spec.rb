# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Options do
  it 'has JS/Python defaults' do
    options = described_class.new
    expect(options.report_missing).to be(false)
    expect(options.enable_conversation_id).to be(false)
    expect(options.enable_exception_autocapture).to be(true)
    expect(options.context_enabled?).to be(true)
    expect(options.context_description).to be_nil
    expect(options.capture_model_enabled?).to be(false)
    expect(PostHog::MCP::Tools.missing_capability_tool_name(options)).to eq('get_more_tools')
  end

  it 'normalises hash forms' do
    options = described_class.new(context: { description: 'why' }, capture_model: { description: 'which' },
                                  missing_capability_tool_name: 'find_tools')
    expect(options.context_description).to eq('why')
    expect(options.model_description).to eq('which')
    expect(options.capture_model_enabled?).to be(true)
    expect(PostHog::MCP::Tools.missing_capability_tool_name(options)).to eq('find_tools')
    expect(described_class.new(context: false).context_enabled?).to be(false)
  end
end
