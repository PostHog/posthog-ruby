require 'spec_helper'

class PostHog
  RSpec.describe 'FeatureFlagsPoller#get_decide' do
    let(:decide_endpoint) { 'https://app.posthog.com/decide/?v=3' }
    let(:feature_flag_endpoint) { 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret' }
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }
    let(:decide_response) { JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-decide-v3.json')), symbolize_names: true) }

    before do
      # Stub the initial feature flag definitions request
      stub_request(:get, feature_flag_endpoint)
        .with(
          headers: {
            'Accept' => '*/*',
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Bearer testsecret',
            'Host' => 'app.posthog.com',
            'User-Agent' => "posthog-ruby#{PostHog::VERSION}"
          }
        )
        .to_return(status: 200, body: { flags: [] }.to_json)
    end

    it 'makes a basic decide request with just distinct_id' do
      stub_request(:post, decide_endpoint)
        .to_return(status: 200, body: decide_response.to_json)

      result = poller.get_decide("test-distinct-id")

      expect(result).to eq(decide_response.merge(status: 200))
      expect(WebMock).to have_requested(:post, decide_endpoint).with(
        body: {
          distinct_id: "test-distinct-id",
          groups: {},
          person_properties: {},
          group_properties: {},
          token: "testsecret"
        }
      )
    end

    it 'includes all parameters in the request' do
      stub_request(:post, decide_endpoint)
        .to_return(status: 200, body: decide_response.to_json)

      result = poller.get_decide(
        "test-distinct-id",
        groups: { company: "test-company" },
        person_properties: { email: "test@example.com" },
        group_properties: { company: { name: "Test Company" } }
      )

      expect(result).to eq(decide_response.merge(status: 200))
      expect(WebMock).to have_requested(:post, decide_endpoint).with(
        body: {
          distinct_id: "test-distinct-id",
          groups: {
            groups: { company: "test-company" },
            person_properties: { email: "test@example.com" },
            group_properties: { company: { name: "Test Company" } }
          },
          person_properties: {},
          group_properties: {},
          token: "testsecret"
        }
      )
    end

    it 'handles error responses gracefully' do
      stub_request(:post, decide_endpoint)
        .to_return(status: 400, body: { error: "Invalid request" }.to_json)

      result = poller.get_decide("test-distinct-id")

      expect(result).to eq({ error: "Invalid request", status: 400 })
    end

    it 'handles network timeouts' do
      stub_request(:post, decide_endpoint)
        .to_timeout

      expect { poller.get_decide("test-distinct-id") }.to raise_error(Timeout::Error)
    end

    it 'handles quota limited responses' do
      quota_limited_response = decide_response.merge(quotaLimited: ["feature_flags"])
      stub_request(:post, decide_endpoint)
        .to_return(status: 200, body: quota_limited_response.to_json)

      result = poller.get_decide("test-distinct-id")

      expect(result).to eq(quota_limited_response.merge(status: 200))
    end

    it 'handles empty responses' do
      stub_request(:post, decide_endpoint)
        .to_return(status: 200, body: {}.to_json)

      result = poller.get_decide("test-distinct-id")

      expect(result).to eq({ status: 200 })
    end

    it 'handles malformed JSON responses' do
      stub_request(:post, decide_endpoint)
        .to_return(status: 200, body: "invalid json")

      result = poller.get_decide("test-distinct-id")

      expect(result).to eq({
        error: "Invalid JSON response",
        body: "invalid json",
        status: 200
      })
    end
  end
end 