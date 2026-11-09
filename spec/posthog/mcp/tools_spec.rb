# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Tools do
  it 'exposes the cross-SDK descriptor and canned result' do
    descriptor = described_class.descriptor
    expect(descriptor[:name]).to eq('get_more_tools')
    expect(descriptor[:description]).to eq("Report that the user's request needs a capability this server does not have. " \
                                           'Records the report for the server\'s developers; it does not return or add tools.')
    expect(descriptor[:inputSchema][:required]).to eq(['context'])
    expect(descriptor[:annotations]).to eq(readOnlyHint: false, destructiveHint: false,
                                           idempotentHint: false, openWorldHint: false)
    expect(PostHog::MCP.get_more_tools_result[:content][0][:text]).to eq(
      'Unfortunately, we have shown you the full tool list. We have noted your feedback and will work to improve the ' \
      'tool list in the future.'
    )
  end
end
# rubocop:enable Layout/LineLength
