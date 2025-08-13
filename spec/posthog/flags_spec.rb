# frozen_string_literal: true

require 'spec_helper'
require 'posthog/client'

module PostHog
  describe 'FeatureFlagsPoller#get_flags' do
    let(:flags_endpoint) { 'https://app.posthog.com/flags/?v=2' }
    let(:feature_flag_endpoint) { 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true' }
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

  describe 'FeatureFlagsPoller#get_remote_config_payload' do
    let(:remote_config_endpoint) { 'https://app.posthog.com/api/projects/@current/feature_flags/test-flag/remote_config?token=testsecret' }
    let(:feature_flag_endpoint) { 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true' }
    let(:client) { Client.new(api_key: 'testsecret', personal_api_key: 'personal_key', test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }

    before do
      # Stub the initial feature flag definitions request
      stub_request(:get, feature_flag_endpoint)
        .to_return(status: 200, body: { flags: [] }.to_json)
    end

    it 'includes project API key token in remote config URL' do
      # Mock response
      remote_config_response = { test: 'payload' }

      stub_request(:get, remote_config_endpoint)
        .with(
          headers: {
            'Accept' => '*/*',
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Content-Type' => 'application/json',
            'Authorization' => 'Bearer personal_key',
            'Host' => 'app.posthog.com',
            'User-Agent' => "posthog-ruby#{PostHog::VERSION}"
          }
        )
        .to_return(status: 200, body: remote_config_response.to_json)

      result = poller.get_remote_config_payload('test-flag')

      expect(result[:test]).to eq('payload')

      # Verify the request was made to the correct URL with token parameter
      expect(WebMock).to have_requested(:get, remote_config_endpoint)
    end
  end

  describe 'Cohort evaluation' do
    describe '.match_cohort' do
      it 'matches simple cohort with AND logic' do
        property = { type: 'cohort', value: 'cohort_1' }
        property_values = { country: 'US', age: 25 }
        cohort_properties = {
          'cohort_1' => {
            'type' => 'AND',
            'values' => [
              { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' },
              { 'key' => 'age', 'operator' => 'gte', 'value' => 18 }
            ]
          }
        }

        result = PostHog::FeatureFlagsPoller.match_cohort(property, property_values, cohort_properties)
        expect(result).to be true
      end

      it 'matches cohort with OR logic' do
        property = { type: 'cohort', value: 'cohort_1' }
        property_values = { country: 'CA', age: 16 }
        cohort_properties = {
          'cohort_1' => {
            'type' => 'OR',
            'values' => [
              { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' },
              { 'key' => 'country', 'operator' => 'exact', 'value' => 'CA' }
            ]
          }
        }

        result = PostHog::FeatureFlagsPoller.match_cohort(property, property_values, cohort_properties)
        expect(result).to be true
      end

      it 'handles nested cohorts with complex property groups' do
        property = { type: 'cohort', value: 'premium_users' }
        property_values = { country: 'US', age: 25, subscription: 'premium' }
        cohort_properties = {
          'premium_users' => {
            'type' => 'AND',
            'values' => [
              {
                'type' => 'OR',
                'values' => [
                  { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' },
                  { 'key' => 'country', 'operator' => 'exact', 'value' => 'CA' }
                ]
              },
              { 'key' => 'subscription', 'operator' => 'exact', 'value' => 'premium' }
            ]
          }
        }

        result = PostHog::FeatureFlagsPoller.match_cohort(property, property_values, cohort_properties)
        expect(result).to be true
      end

      it 'raises InconclusiveMatchError when cohort not found' do
        property = { type: 'cohort', value: 'non_existent_cohort' }
        property_values = { country: 'US' }
        cohort_properties = {}

        expect do
          PostHog::FeatureFlagsPoller.match_cohort(property, property_values, cohort_properties)
        end.to raise_error(PostHog::InconclusiveMatchError, "can't match cohort without a given cohort property value")
      end

      it 'handles empty cohort definitions gracefully' do
        property = { type: 'cohort', value: 'empty_cohort' }
        property_values = { country: 'US' }
        cohort_properties = {
          'empty_cohort' => {
            'type' => 'AND',
            'values' => []
          }
        }

        result = PostHog::FeatureFlagsPoller.match_cohort(property, property_values, cohort_properties)
        expect(result).to be true # Empty conditions should return true
      end

      it 'handles cohort with missing properties in user data' do
        property = { type: 'cohort', value: 'cohort_1' }
        property_values = { country: 'US' } # Missing 'age' property
        cohort_properties = {
          'cohort_1' => {
            'type' => 'AND',
            'values' => [
              { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' },
              { 'key' => 'age', 'operator' => 'gte', 'value' => 18 }
            ]
          }
        }

        expect do
          PostHog::FeatureFlagsPoller.match_cohort(property, property_values, cohort_properties)
        end.to raise_error(PostHog::InconclusiveMatchError, "can't match cohort without a given cohort property value")
      end
    end

    describe '.match_property_group' do
      it 'handles cohorts within property groups' do
        property_group = {
          'type' => 'AND',
          'values' => [
            { 'type' => 'cohort', 'value' => 'cohort_1' },
            { 'key' => 'premium', 'operator' => 'exact', 'value' => true }
          ]
        }
        property_values = { country: 'US', age: 25, premium: true }
        cohort_properties = {
          'cohort_1' => {
            'type' => 'AND',
            'values' => [
              { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' },
              { 'key' => 'age', 'operator' => 'gte', 'value' => 18 }
            ]
          }
        }

        result = PostHog::FeatureFlagsPoller.match_property_group(property_group, property_values, cohort_properties)
        expect(result).to be true
      end

      it 'returns true for empty property groups' do
        result = PostHog::FeatureFlagsPoller.match_property_group(nil, {}, {})
        expect(result).to be true

        result = PostHog::FeatureFlagsPoller.match_property_group({}, {}, {})
        expect(result).to be true

        result = PostHog::FeatureFlagsPoller.match_property_group({ 'values' => [] }, {}, {})
        expect(result).to be true
      end

      it 'handles OR logic property groups' do
        property_group = {
          'type' => 'OR',
          'values' => [
            { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' },
            { 'key' => 'country', 'operator' => 'exact', 'value' => 'CA' }
          ]
        }
        property_values = { country: 'CA', age: 25 }

        result = PostHog::FeatureFlagsPoller.match_property_group(property_group, property_values, {})
        expect(result).to be true
      end

      it 'handles complex nested AND/OR combinations' do
        # Top-level OR with nested AND groups
        property_group = {
          'type' => 'OR',
          'values' => [
            {
              'type' => 'AND',
              'values' => [
                { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' },
                { 'key' => 'age', 'operator' => 'gte', 'value' => 21 }
              ]
            },
            {
              'type' => 'AND',
              'values' => [
                { 'key' => 'country', 'operator' => 'exact', 'value' => 'CA' },
                { 'key' => 'age', 'operator' => 'gte', 'value' => 18 }
              ]
            }
          ]
        }

        # Should match the second condition (CA, 19)
        property_values = { country: 'CA', age: 19 }
        result = PostHog::FeatureFlagsPoller.match_property_group(property_group, property_values, {})
        expect(result).to be true

        # Should not match either condition
        property_values = { country: 'UK', age: 25 }
        result = PostHog::FeatureFlagsPoller.match_property_group(property_group, property_values, {})
        expect(result).to be false
      end

      it 'handles mixed cohort and regular properties' do
        property_group = {
          'type' => 'AND',
          'values' => [
            { 'type' => 'cohort', 'value' => 'us_users' },
            { 'key' => 'premium', 'operator' => 'exact', 'value' => true },
            { 'key' => 'age', 'operator' => 'gte', 'value' => 21 }
          ]
        }

        property_values = { country: 'US', premium: true, age: 25 }
        cohort_properties = {
          'us_users' => {
            'type' => 'OR',
            'values' => [
              { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' },
              { 'key' => 'country', 'operator' => 'exact', 'value' => 'CA' }
            ]
          }
        }

        result = PostHog::FeatureFlagsPoller.match_property_group(property_group, property_values, cohort_properties)
        expect(result).to be true
      end

      it 'handles property negation in cohorts' do
        property_group = {
          'type' => 'AND',
          'values' => [
            { 'key' => 'country', 'operator' => 'exact', 'value' => 'US', 'negation' => true },
            { 'key' => 'age', 'operator' => 'gte', 'value' => 18 }
          ]
        }

        # Should match because country is NOT US and age >= 18
        property_values = { country: 'CA', age: 25 }
        result = PostHog::FeatureFlagsPoller.match_property_group(property_group, property_values, {})
        expect(result).to be true

        # Should not match because country IS US (negated condition fails)
        property_values = { country: 'US', age: 25 }
        result = PostHog::FeatureFlagsPoller.match_property_group(property_group, property_values, {})
        expect(result).to be false
      end

      it 'handles cohorts referencing other cohorts' do
        property_group = {
          'type' => 'OR',
          'values' => [
            { 'type' => 'cohort', 'value' => 'us_users' },
            { 'type' => 'cohort', 'value' => 'premium_users' }
          ]
        }

        property_values = { country: 'CA', subscription: 'premium' }
        cohort_properties = {
          'us_users' => {
            'type' => 'AND',
            'values' => [
              { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' }
            ]
          },
          'premium_users' => {
            'type' => 'AND',
            'values' => [
              { 'key' => 'subscription', 'operator' => 'exact', 'value' => 'premium' }
            ]
          }
        }

        # Should match premium_users cohort even though not in us_users
        result = PostHog::FeatureFlagsPoller.match_property_group(property_group, property_values, cohort_properties)
        expect(result).to be true
      end

      it 'handles unknown property group types' do
        property_group = {
          'type' => 'XOR', # Invalid type
          'values' => [
            { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' }
          ]
        }

        property_values = { country: 'US' }

        expect do
          PostHog::FeatureFlagsPoller.match_property_group(property_group, property_values, {})
        end.to raise_error(PostHog::InconclusiveMatchError, 'Unknown property group type: XOR')
      end
    end

    describe 'integration with feature flags' do
      let(:feature_flag_endpoint) { 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true' }
      let(:client) { Client.new(api_key: 'testsecret', personal_api_key: 'personal_key', test_mode: true) }
      let(:poller) { client.instance_variable_get(:@feature_flags_poller) }

      before do
        flag_definitions = {
          flags: [
            {
              key: 'cohort-flag',
              active: true,
              filters: {
                groups: [
                  {
                    properties: [
                      { type: 'cohort', value: 'us_users' }
                    ],
                    rollout_percentage: 100
                  }
                ]
              }
            }
          ],
          group_type_mapping: {},
          cohorts: {
            'us_users' => {
              'type' => 'AND',
              'values' => [
                { 'key' => 'country', 'operator' => 'exact', 'value' => 'US' }
              ]
            }
          }
        }

        stub_request(:get, feature_flag_endpoint)
          .to_return(status: 200, body: flag_definitions.to_json)
      end

      it 'evaluates flags with cohorts locally' do
        poller.load_feature_flags

        result, locally_evaluated, _request_id = poller.get_feature_flag(
          'cohort-flag',
          'user123',
          {},
          { country: 'US' }
        )

        expect(result).to be true
        expect(locally_evaluated).to be true
      end

      it 'fails to evaluate flags with cohorts when user not in cohort' do
        poller.load_feature_flags

        result, locally_evaluated, _request_id = poller.get_feature_flag(
          'cohort-flag',
          'user123',
          {},
          { country: 'CA' }
        )

        expect(result).to be false
        expect(locally_evaluated).to be true
      end
    end
  end
end
