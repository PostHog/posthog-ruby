# frozen_string_literal: true

require 'spec_helper'
require 'posthog/client'

class PostHog
  describe 'FeatureFlagsPoller#get_flags' do
    let(:flags_endpoint) { 'https://app.posthog.com/flags/?v=2' }
    let(:feature_flag_endpoint) { 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret' }
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }
    let(:decide_v3_response) do
      JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-decide-v3.json')), symbolize_names: true)
    end
    let(:decide_v4_response) do
      JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-decide-v4.json')), symbolize_names: true)
    end
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
      let(:flags_response) do
        JSON.parse(File.read(File.join(__dir__, 'fixtures', "test-decide-#{version}.json")), symbolize_names: true)
      end

      it 'correctly parses the response' do
        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: flags_response.to_json)

        result = poller.get_flags('test-distinct-id')

        # Verify the complete response structure
        expect(result[:config]).to eq(enable_collect_everything: true)
        expect(result[:featureFlags]).to include(
          'enabled-flag': true,
          'group-flag': true,
          'disabled-flag': false,
          'multi-variate-flag': 'hello',
          'simple-flag': true,
          'beta-feature': 'decide-fallback-value',
          'beta-feature2': 'variant-2'
        )
        expect(result[:featureFlagPayloads]).to include(
          'enabled-flag': '{"foo": 1}',
          'simple-flag': '{"bar": 2}',
          'continuation-flag': '{"foo": "bar"}',
          'beta-feature': '{"foo": "bar"}',
          'test-get-feature': 'this is a string',
          'multi-variate-flag': 'this is the payload'
        )
        expect(result[:status]).to eq(200)
        expect(result[:sessionRecording]).to be false
        expect(result[:supportedCompression]).to eq(%w[gzip gzip-js lz64])
      end
    end

    context 'with v3 response format' do
      it_behaves_like 'decide response format', 'v3'
    end

    context 'with v4 response format' do
      it_behaves_like 'decide response format', 'v4'
    end

    it 'transforms v3 response flags into v4 format' do
      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: decide_v3_response.to_json)

      result = poller.get_flags('test-distinct-id')

      # Verify v3 to v4 transformation
      # We'll assert a sampling of the fields
      expect(result[:flags]).to be_present
      expect(result[:flags].keys).to contain_exactly(
        :'enabled-flag',
        :'group-flag',
        :'disabled-flag',
        :'multi-variate-flag',
        :'simple-flag',
        :'beta-feature',
        :'beta-feature2',
        :'false-flag-2',
        :'test-get-feature',
        :'continuation-flag'
      )

      enabled_flag = result[:flags][:'enabled-flag']
      expect(enabled_flag).to have_attributes(
        class: FeatureFlag,
        key: :'enabled-flag',
        enabled: true,
        variant: nil,
        reason: nil,
        metadata: have_attributes(
          payload: '{"foo": 1}'
        )
      )

      multi_variate_flag = result[:flags][:'multi-variate-flag']
      expect(multi_variate_flag).to have_attributes(
        class: FeatureFlag,
        key: :'multi-variate-flag',
        enabled: true,
        variant: 'hello',
        reason: nil,
        metadata: have_attributes(
          payload: 'this is the payload'
        )
      )

      disabled_flag = result[:flags][:'disabled-flag']
      expect(disabled_flag).to have_attributes(
        class: FeatureFlag,
        key: :'disabled-flag',
        enabled: false,
        variant: nil,
        reason: nil,
        metadata: have_attributes(
          payload: nil
        )
      )
    end

    it 'transforms v4 response flags into hash of FeatureFlag instances' do
      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: decide_v4_response.to_json)

      result = poller.get_flags('test-distinct-id')

      # We'll assert a sampling of the fields
      expect(result[:flags]).to be_present
      expect(result[:flags].keys).to contain_exactly(
        :'enabled-flag',
        :'group-flag',
        :'disabled-flag',
        :'multi-variate-flag',
        :'simple-flag',
        :'beta-feature',
        :'beta-feature2',
        :'false-flag-2',
        :'test-get-feature',
        :'continuation-flag'
      )

      enabled_flag = result[:flags][:'enabled-flag']

      expect(enabled_flag).to have_attributes(
        class: FeatureFlag,
        key: 'enabled-flag',
        enabled: true,
        variant: nil,
        reason: have_attributes(
          class: EvaluationReason,
          code: 'condition_match',
          description: 'Matched conditions set 3',
          condition_index: 2
        ),
        metadata: have_attributes(
          id: 1,
          version: 23,
          payload: '{"foo": 1}',
          description: 'This is an enabled flag'
        )
      )

      multi_variate_flag = result[:flags][:'multi-variate-flag']
      expect(multi_variate_flag).to have_attributes(
        class: FeatureFlag,
        key: 'multi-variate-flag',
        enabled: true,
        variant: 'hello',
        reason: have_attributes(
          class: EvaluationReason,
          code: 'condition_match',
          description: 'Matched conditions set 2',
          condition_index: 1
        ),
        metadata: have_attributes(
          id: 4,
          version: 42,
          payload: 'this is the payload'
        )
      )

      disabled_flag = result[:flags][:'disabled-flag']
      expect(disabled_flag).to have_attributes(
        class: FeatureFlag,
        key: 'disabled-flag',
        enabled: false,
        variant: nil,
        reason: have_attributes(
          class: EvaluationReason,
          code: 'no_condition_match',
          description: 'No matching condition set',
          condition_index: nil
        ),
        metadata: have_attributes(
          id: 3,
          version: 12,
          payload: nil
        )
      )
    end

    it 'handles error responses gracefully' do
      stub_request(:post, flags_endpoint)
        .to_return(status: 400, body: { error: 'Invalid request' }.to_json)

      result = poller.get_flags('test-distinct-id')

      expect(result).to eq({ error: 'Invalid request', status: 400 })
    end

    it 'handles network timeouts' do
      stub_request(:post, flags_endpoint)
        .to_timeout

      expect { poller.get_flags('test-distinct-id') }.to raise_error(Timeout::Error)
    end

    it 'handles quota limited responses v3' do
      quota_limited_response = {
        flags: {},
        featureFlags: {},
        featureFlagPayloads: {},
        errorsWhileComputingFlags: true,
        quotaLimited: ['feature_flags']
      }
      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: quota_limited_response.to_json)

      result = poller.get_flags('test-distinct-id')

      expect(result).to eq(quota_limited_response.merge(status: 200))
    end

    it 'handles empty responses' do
      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: {}.to_json)

      result = poller.get_flags('test-distinct-id')

      expect(result).to eq({ status: 200 })
    end

    it 'handles malformed JSON responses' do
      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: 'invalid json')

      result = poller.get_flags('test-distinct-id')

      expect(result).to eq({
                             error: 'Invalid JSON response',
                             body: 'invalid json',
                             status: 200
                           })
    end
  end

  describe FeatureFlag do
    let(:decide_v4_response) do
      JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-decide-v4.json')), symbolize_names: true)
    end

    it 'transforms v4 response flags into hash of FeatureFlag instances' do
      json = decide_v4_response[:flags][:'enabled-flag']

      result = FeatureFlag.new(json)

      expect(result).to have_attributes(
        class: FeatureFlag,
        key: 'enabled-flag',
        enabled: true,
        variant: nil,
        reason: have_attributes(
          class: EvaluationReason,
          code: 'condition_match',
          description: 'Matched conditions set 3'
        )
      )
    end

    it 'transforms a hash into a FeatureFlag instance' do
      result = FeatureFlag.new({
                                 'key' => 'enabled-flag',
                                 'enabled' => true,
                                 'variant' => nil,
                                 'reason' => {
                                   'code' => 'condition_match',
                                   'description' => 'Matched conditions set 3',
                                   'condition_index' => 2
                                 },
                                 'metadata' => {
                                   'id' => 1,
                                   'version' => 23,
                                   'payload' => '{"foo": 1}',
                                   'description' => 'This is an enabled flag'
                                 }
                               })

      expect(result).to have_attributes(
        class: FeatureFlag,
        key: 'enabled-flag',
        enabled: true,
        variant: nil,
        reason: have_attributes(
          class: EvaluationReason,
          code: 'condition_match',
          description: 'Matched conditions set 3',
          condition_index: 2
        ),
        metadata: have_attributes(
          class: FeatureFlagMetadata,
          id: 1,
          version: 23,
          payload: '{"foo": 1}',
          description: 'This is an enabled flag'
        )
      )
    end
  end

  describe 'Client#get_feature_flag' do
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: nil, test_mode: true) }
    let(:flags_endpoint) { 'https://app.posthog.com/flags/?v=2' }
    let(:decide_v4_response) do
      JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-decide-v4.json')), symbolize_names: true)
    end
    describe '#get_feature_flag' do
      it 'calls the $feature_flag_called event with additional properties' do
        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: decide_v4_response.to_json)
        stub_const('PostHog::VERSION', '2.8.0')

        expect(client.get_feature_flag('enabled-flag', 'test-distinct-id')).to eq(true)

        captured_message = client.dequeue_last_message
        expect(captured_message[:event]).to eq('$feature_flag_called')
        expect(captured_message[:properties]).to(
          eq({
               '$feature_flag' => 'enabled-flag',
               '$feature_flag_response' => true,
               '$feature_flag_request_id' => '42853c54-1431-4861-996e-3a548989fa2c',
               '$lib' => 'posthog-ruby',
               '$lib_version' => '2.8.0',
               '$groups' => {},
               'locally_evaluated' => false
             })
        )
      end
    end
  end
end
