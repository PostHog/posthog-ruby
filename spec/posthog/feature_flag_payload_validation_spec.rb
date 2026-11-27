# frozen_string_literal: true

require 'spec_helper'

# A flag payload that isn't valid JSON reads as no payload, rather than being
# handed to the caller as a string it cannot decode. See
# https://github.com/PostHog/sdk-specs `get-feature-flag-payload`.
RSpec.describe 'feature flag payload validation' do
  let(:definitions_endpoint) do
    'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true'
  end
  let(:flags_endpoint) { 'https://us.i.posthog.com/flags/?v=2' }

  def local_flag(key, payload)
    {
      id: 1,
      key: key,
      active: true,
      is_simple_flag: true,
      filters: {
        groups: [{ properties: [], rollout_percentage: 100 }],
        payloads: { 'true' => payload }
      }
    }
  end

  def client_with_definitions(flags)
    stub_request(:get, definitions_endpoint)
      .to_return(status: 200, body: { flags: flags }.to_json)
    PostHog::Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
  end

  ['{broken', '', '   ', 'bare-word'].each do |malformed|
    it "returns no payload for the locally evaluated payload #{malformed.inspect}" do
      client = client_with_definitions([local_flag('checkout', malformed), local_flag('beta-ui', '{"color":"green"}')])

      flags = client.evaluate_flags('distinct-id', only_evaluate_locally: true)

      expect(flags.get_flag_payload('checkout')).to be_nil
      expect(flags.get_flag('checkout')).to be true
      expect(flags.get_flag_payload('beta-ui')).to eq({ 'color' => 'green' })
    ensure
      client&.shutdown
    end
  end

  it 'returns no payload when a remotely evaluated payload is not valid JSON' do
    stub_request(:get, definitions_endpoint).to_return(status: 200, body: { flags: [] }.to_json)
    stub_request(:post, flags_endpoint).to_return(
      status: 200,
      body: {
        flags: {
          'checkout' => { key: 'checkout', enabled: true, variant: 'blue',
                          metadata: { payload: '{broken' } },
          'beta-ui' => { key: 'beta-ui', enabled: true,
                         metadata: { payload: '{"color":"green"}' } }
        }
      }.to_json
    )
    client = PostHog::Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

    flags = client.evaluate_flags('distinct-id')

    expect(flags.get_flag_payload('checkout')).to be_nil
    expect(flags.get_flag('checkout')).to eq('blue')
    expect(flags.get_flag_payload('beta-ui')).to eq({ 'color' => 'green' })
  ensure
    client&.shutdown
  end

  it 'logs the parse failure through SDK diagnostics' do
    client = client_with_definitions([local_flag('checkout', '{broken')])
    expect(PostHog::Logging.logger).to receive(:warn).with(/not valid JSON/).at_least(:once)

    client.evaluate_flags('distinct-id', only_evaluate_locally: true)
  ensure
    client&.shutdown
  end

  describe 'the deprecated payload getter' do
    it 'returns no payload for a malformed stored payload and keeps a valid one serialized' do
      client = client_with_definitions([local_flag('checkout', '{broken'), local_flag('beta-ui', '{"color":"green"}')])

      expect(client.get_feature_flag_payload('checkout', 'distinct-id', only_evaluate_locally: true)).to be_nil
      expect(client.get_feature_flag_payload('beta-ui', 'distinct-id', only_evaluate_locally: true))
        .to eq('{"color":"green"}')
    ensure
      client&.shutdown
    end
  end
end
