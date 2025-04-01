require 'spec_helper'

class PostHog
  RSpec.describe 'FeatureFlagsPoller#get_decide' do
    let(:decide_endpoint) { 'https://app.posthog.com/decide/?v=3' }
    let(:feature_flag_endpoint) { 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret' }
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }
    let(:decide_v3_response) { JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-decide-v3.json')), symbolize_names: true) }

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

    shared_examples 'decide response format' do |version|
      let(:decide_response) { JSON.parse(File.read(File.join(__dir__, 'fixtures', "test-decide-#{version}.json")), symbolize_names: true) }

      it 'correctly parses the response' do
        stub_request(:post, decide_endpoint)
          .to_return(status: 200, body: decide_response.to_json)

        result = poller.get_decide("test-distinct-id")

        # Verify the complete response structure
        expect(result[:config]).to eq(enable_collect_everything: true)
        expect(result[:featureFlags]).to include(
          "enabled-flag": true,
          "group-flag": true,
          "disabled-flag": false,
          "multi-variate-flag": "hello",
          "simple-flag": true,
          "beta-feature": "decide-fallback-value",
          "beta-feature2": "variant-2"
        )
        expect(result[:featureFlagPayloads]).to include(
          "enabled-flag": "{\"foo\": 1}",
          "simple-flag": "{\"bar\": 2}",
          "continuation-flag": "{\"foo\": \"bar\"}",
          "beta-feature": "{\"foo\": \"bar\"}",
          "test-get-feature": "this is a string",
          "multi-variate-flag": "this is the payload"
        )
        expect(result[:status]).to eq(200)
        expect(result[:sessionRecording]).to be false
        expect(result[:supportedCompression]).to eq(["gzip", "gzip-js", "lz64"])
      end
    end

    context 'with v3 response format' do
      it_behaves_like 'decide response format', 'v3'
    end

    context 'with v4 response format' do
      it_behaves_like 'decide response format', 'v4'
    end

    it 'transforms v3 response flags into v4 format' do
      stub_request(:post, decide_endpoint)
        .to_return(status: 200, body: decide_v3_response.to_json)

      result = poller.get_decide("test-distinct-id")

      # Verify v3 to v4 transformation
      # We'll assert a sampling of the fields
      expect(result[:flags]).to be_present
      expect(result[:flags].keys).to eq([:"enabled-flag", :"group-flag", :"disabled-flag", :"multi-variate-flag", :"simple-flag", :"beta-feature", :"beta-feature2", :"false-flag-2", :"test-get-feature", :"continuation-flag"])

      enabled_flag = result[:flags][:"enabled-flag"]
      expect(enabled_flag).to be_a(FeatureFlag)

      expect(enabled_flag).to be_a(FeatureFlag)
      expect(enabled_flag.key).to eq(:"enabled-flag")
      expect(enabled_flag.enabled).to be true
      expect(enabled_flag.variant).to be nil
      expect(enabled_flag.reason).to be nil
      expect(enabled_flag.metadata.payload).to eq("{\"foo\": 1}")

      multi_variate_flag = result[:flags][:"multi-variate-flag"]
      expect(multi_variate_flag).to be_a(FeatureFlag)
      expect(multi_variate_flag.key).to eq(:"multi-variate-flag")
      expect(multi_variate_flag.enabled).to be true
      expect(multi_variate_flag.variant).to eq("hello")
      expect(multi_variate_flag.reason).to be nil
      expect(multi_variate_flag.metadata.payload).to eq("this is the payload")

      disabled_flag = result[:flags][:"disabled-flag"]
      expect(disabled_flag).to be_a(FeatureFlag)
      expect(disabled_flag.key).to eq(:"disabled-flag")
      expect(disabled_flag.enabled).to be false
      expect(disabled_flag.variant).to be nil
      expect(disabled_flag.reason).to be nil
      expect(disabled_flag.metadata.payload).to be nil
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

    it 'handles quota limited responses v3' do
      quota_limited_response = {
        flags: {},
        featureFlags: {},
        featureFlagPayloads: {},
        errorsWhileComputingFlags: true,
        quotaLimited: ["feature_flags"]
      }
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