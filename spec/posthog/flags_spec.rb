# frozen_string_literal: true

require 'spec_helper'
require 'posthog/client'

module PostHog
  describe 'FeatureFlagsPoller#get_flags' do
    let(:flags_endpoint) { 'https://us.i.posthog.com/flags/?v=2' }
    let(:feature_flag_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }
    let(:flags_v3_response) do
      JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-flags-v3.json')), symbolize_names: true)
    end
    let(:flags_v4_response) do
      JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-flags-v4.json')), symbolize_names: true)
    end
    before do
      # Stub the initial feature flag definitions request
      stub_request(:get, feature_flag_endpoint)
        .with(
          headers: {
            'Accept' => '*/*',
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Bearer testsecret',
            'Host' => 'us.i.posthog.com',
            'User-Agent' => "posthog-ruby/#{PostHog::VERSION}"
          }
        )
        .to_return(status: 200, body: { flags: [] }.to_json)
    end

    shared_examples 'flags response format' do |version|
      let(:flags_response) do
        JSON.parse(File.read(File.join(__dir__, 'fixtures', "test-flags-#{version}.json")), symbolize_names: true)
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
      it_behaves_like 'flags response format', 'v3'
    end

    context 'with v4 response format' do
      it_behaves_like 'flags response format', 'v4'
    end

    it 'transforms v3 response flags into v4 format' do
      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: flags_v3_response.to_json)

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
        .to_return(status: 200, body: flags_v4_response.to_json)

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
      # A timeout is retryable now, so stub sleep to avoid real backoff delay.
      allow(poller).to receive(:sleep)
      stub_request(:post, flags_endpoint)
        .to_timeout

      expect { poller.get_flags('test-distinct-id') }.to raise_error(Timeout::Error)
    end

    context 'retrying transient network errors' do
      let(:flags_response) { { featureFlags: { 'my-flag' => true }, featureFlagPayloads: {} } }

      before do
        # Avoid real backoff sleeps in tests.
        allow(poller).to receive(:sleep)
      end

      it 'retries once and succeeds after a transient Net::ReadTimeout' do
        stub_request(:post, flags_endpoint)
          .to_raise(Net::ReadTimeout).then
          .to_return(status: 200, body: flags_response.to_json)

        result = poller.get_flags('test-distinct-id')

        expect(result[:status]).to eq(200)
        expect(result[:featureFlags]).to eq({ 'my-flag': true })
        expect(a_request(:post, flags_endpoint)).to have_been_made.times(2)
        expect(poller).to have_received(:sleep).once
      end

      [502, 504].each do |status|
        it "retries once and succeeds after HTTP #{status}" do
          stub_request(:post, flags_endpoint)
            .to_return(status: status, body: { error: 'temporary' }.to_json).then
            .to_return(status: 200, body: flags_response.to_json)

          result = poller.get_flags('test-distinct-id')

          expect(result[:status]).to eq(200)
          expect(result[:featureFlags]).to eq({ 'my-flag': true })
          expect(a_request(:post, flags_endpoint)).to have_been_made.times(2)
          expect(poller).to have_received(:sleep).once
        end
      end

      it 'does not retry other HTTP statuses' do
        stub_request(:post, flags_endpoint)
          .to_return(status: 500, body: { error: 'internal error' }.to_json).then
          .to_return(status: 200, body: flags_response.to_json)

        result = poller.get_flags('test-distinct-id')

        expect(result).to eq({ error: 'internal error', status: 500 })
        expect(a_request(:post, flags_endpoint)).to have_been_made.times(1)
        expect(poller).not_to have_received(:sleep)
      end

      it 'retries on Errno::ECONNRESET then re-raises once retries are exhausted' do
        stub_request(:post, flags_endpoint)
          .to_raise(Errno::ECONNRESET)

        expect { poller.get_flags('test-distinct-id') }.to raise_error(Errno::ECONNRESET)
        expect(a_request(:post, flags_endpoint)).to have_been_made.times(2)
      end

      it 'does not retry on a connection refused error' do
        stub_request(:post, flags_endpoint)
          .to_raise(Errno::ECONNREFUSED)

        expect { poller.get_flags('test-distinct-id') }.to raise_error(Errno::ECONNREFUSED)
        expect(a_request(:post, flags_endpoint)).to have_been_made.times(1)
      end

      it 'does not retry on a non-retryable network error' do
        stub_request(:post, flags_endpoint)
          .to_raise(Net::HTTPBadResponse)

        expect { poller.get_flags('test-distinct-id') }.to raise_error(Net::HTTPBadResponse)
        expect(a_request(:post, flags_endpoint)).to have_been_made.times(1)
      end

      context 'when feature_flag_request_max_retries is configured' do
        let(:client) do
          Client.new(
            api_key: API_KEY,
            personal_api_key: API_KEY,
            test_mode: true,
            feature_flag_request_max_retries: max_retries
          )
        end

        context 'set to 0 (opt out)' do
          let(:max_retries) { 0 }

          it 'does not retry and re-raises the transient error immediately' do
            stub_request(:post, flags_endpoint)
              .to_raise(Net::ReadTimeout)

            expect { poller.get_flags('test-distinct-id') }.to raise_error(Net::ReadTimeout)
            expect(a_request(:post, flags_endpoint)).to have_been_made.times(1)
            expect(poller).not_to have_received(:sleep)
          end

          it 'does not retry HTTP 502 responses' do
            stub_request(:post, flags_endpoint)
              .to_return(status: 502, body: { error: 'temporary' }.to_json).then
              .to_return(status: 200, body: flags_response.to_json)

            result = poller.get_flags('test-distinct-id')

            expect(result).to eq({ error: 'temporary', status: 502 })
            expect(a_request(:post, flags_endpoint)).to have_been_made.times(1)
            expect(poller).not_to have_received(:sleep)
          end
        end

        context 'set to a higher count' do
          let(:max_retries) { 3 }

          it 'retries up to the configured number of times before re-raising' do
            stub_request(:post, flags_endpoint)
              .to_raise(Errno::ECONNRESET)

            expect { poller.get_flags('test-distinct-id') }.to raise_error(Errno::ECONNRESET)
            expect(a_request(:post, flags_endpoint)).to have_been_made.times(4)
          end

          [502, 504].each do |status|
            it "retries HTTP #{status} up to the configured number of times before returning the response" do
              stub_request(:post, flags_endpoint)
                .to_return(status: status, body: { error: 'temporary' }.to_json)

              result = poller.get_flags('test-distinct-id')

              expect(result).to eq({ error: 'temporary', status: status })
              expect(a_request(:post, flags_endpoint)).to have_been_made.times(4)
              expect(poller).to have_received(:sleep).exactly(3).times
            end
          end
        end
      end
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
    let(:flags_v4_response) do
      JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-flags-v4.json')), symbolize_names: true)
    end

    it 'transforms v4 response flags into hash of FeatureFlag instances' do
      json = flags_v4_response[:flags][:'enabled-flag']

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
          description: 'This is an enabled flag',
          has_experiment: nil
        )
      )
    end

    it 'parses has_experiment from metadata' do
      result = FeatureFlag.new({
                                 'key' => 'experiment-flag',
                                 'enabled' => true,
                                 'variant' => nil,
                                 'metadata' => {
                                   'id' => 1,
                                   'version' => 23,
                                   'has_experiment' => true
                                 }
                               })

      expect(result.metadata.has_experiment).to be(true)
    end
  end

  describe 'Client#get_feature_flag' do
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: nil, test_mode: true) }
    let(:flags_endpoint) { 'https://us.i.posthog.com/flags/?v=2' }
    let(:flags_v4_response) do
      JSON.parse(File.read(File.join(__dir__, 'fixtures', 'test-flags-v4.json')), symbolize_names: true)
    end
    describe '#get_feature_flag' do
      it 'parses flag responses with keyword JSON options' do
        body = { featureFlags: { 'enabled-flag' => true }, featureFlagPayloads: {} }.to_json
        stub_request(:post, flags_endpoint).to_return(status: 200, body: body)
        expect(JSON).to receive(:parse).with(body, symbolize_names: true).and_call_original

        expect(client.get_feature_flag('enabled-flag', 'test-distinct-id')).to eq(true)
      end

      it 'calls the $feature_flag_called event with additional properties' do
        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: flags_v4_response.to_json)
        stub_const('PostHog::VERSION', '2.8.0')

        expect(client.get_feature_flag('enabled-flag', 'test-distinct-id')).to eq(true)

        captured_message = client.dequeue_last_message
        expect(captured_message[:event]).to eq('$feature_flag_called')
        expect(captured_message[:properties]).to(
          eq({
               '$feature_flag' => 'enabled-flag',
               '$feature_flag_response' => true,
               '$feature_flag_request_id' => '42853c54-1431-4861-996e-3a548989fa2c',
               '$feature_flag_evaluated_at' => 1_704_067_200_000,
               '$lib' => 'posthog-ruby',
               '$lib_version' => '2.8.0',
               '$is_server' => true,
               '$groups' => {},
               'locally_evaluated' => false
             })
        )
      end

      it 'accepts symbol flag keys' do
        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: flags_v4_response.to_json)

        expect(client.get_feature_flag(:'enabled-flag', 'test-distinct-id',
                                       send_feature_flag_events: false)).to eq(true)
        expect(client.get_feature_flag_payload(:'enabled-flag', 'test-distinct-id')).to eq('{"foo": 1}')
      end
    end
  end

  describe 'FeatureFlagsPoller#get_remote_config_payload' do
    let(:remote_config_endpoint) { 'https://us.i.posthog.com/api/projects/@current/feature_flags/test-flag/remote_config?token=testsecret' }
    let(:feature_flag_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
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
            'Host' => 'us.i.posthog.com',
            'User-Agent' => "posthog-ruby/#{PostHog::VERSION}"
          }
        )
        .to_return(status: 200, body: remote_config_response.to_json)

      result = poller.get_remote_config_payload('test-flag')

      expect(result[:test]).to eq('payload')

      # Verify the request was made to the correct URL with token parameter
      expect(WebMock).to have_requested(:get, remote_config_endpoint)
    end

    it 'accepts a symbol flag key' do
      remote_config_response = { test: 'payload' }
      stub_request(:get, remote_config_endpoint)
        .to_return(status: 200, body: remote_config_response.to_json)

      result = poller.get_remote_config_payload(:'test-flag')

      expect(result[:test]).to eq('payload')
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

      it 'raises RequiresServerEvaluation when cohort not found' do
        property = { type: 'cohort', value: 'non_existent_cohort' }
        property_values = { country: 'US' }
        cohort_properties = {}

        expect do
          PostHog::FeatureFlagsPoller.match_cohort(property, property_values, cohort_properties)
        end.to raise_error(PostHog::RequiresServerEvaluation,
                           'cohort non_existent_cohort not found in local cohorts - ' \
                           'likely a static cohort that requires server evaluation')
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
      let(:feature_flag_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
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

  describe 'FeatureFlagsPoller.matches_dependency_value' do
    it 'matches string exactly (case-sensitive)' do
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value('control', 'control')).to be true
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value('Control', 'Control')).to be true
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value('control', 'Control')).to be false
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value('Control', 'CONTROL')).to be false
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value('control', 'test')).to be false
    end

    it 'matches string variant with boolean true (any variant is truthy)' do
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value(true, 'control')).to be true
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value(true, 'test')).to be true
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value(false, 'control')).to be false
    end

    it 'matches boolean exactly' do
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value(true, true)).to be true
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value(false, false)).to be true
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value(false, true)).to be false
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value(true, false)).to be false
    end

    it 'does not match empty string' do
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value(true, '')).to be false
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value('control', '')).to be false
    end

    it 'does not match type mismatches' do
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value(123, 'control')).to be false
      expect(PostHog::FeatureFlagsPoller.matches_dependency_value('control', true)).to be false
    end
  end

  describe 'Flag dependencies' do
    let(:flags_endpoint) { 'https://us.i.posthog.com/flags/?v=2' }
    let(:feature_flag_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }

    before do
      # Stub the initial feature flag definitions request
      stub_request(:get, feature_flag_endpoint)
        .with(
          headers: {
            'Accept' => '*/*',
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Bearer testsecret',
            'Host' => 'us.i.posthog.com',
            'User-Agent' => "posthog-ruby/#{PostHog::VERSION}"
          }
        )
        .to_return(status: 200, body: { flags: [] }.to_json)
    end

    it 'evaluates simple flag dependency' do
      stub_feature_flags([
                           {
                             id: 1,
                             name: 'Base Flag',
                             key: 'base-flag',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 2,
                             name: 'Dependent Flag',
                             key: 'dependent-flag',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'base-flag',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: ['base-flag']
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           }
                         ])

      result, locally_evaluated = poller.get_feature_flag('dependent-flag', 'test-user', {}, {}, {}, true)
      expect(result).to be true
      expect(locally_evaluated).to be true
    end

    it 'handles circular dependencies correctly' do
      stub_feature_flags([
                           {
                             id: 1,
                             name: 'Flag A',
                             key: 'flag-a',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'flag-b',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: []  # Empty chain indicates circular dependency
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 2,
                             name: 'Flag B',
                             key: 'flag-b',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'flag-a',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: []  # Empty chain indicates circular dependency
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           }
                         ])

      # Should return [nil, false] due to circular dependency falling back to remote (but no remote call made)
      result, locally_evaluated = poller.get_feature_flag('flag-a', 'test-user', {}, {}, {}, true)
      expect(result).to be_nil
      expect(locally_evaluated).to be false

      result, locally_evaluated = poller.get_feature_flag('flag-b', 'test-user', {}, {}, {}, true)
      expect(result).to be_nil
      expect(locally_evaluated).to be false
    end

    it 'handles missing flag dependency' do
      stub_feature_flags([
                           {
                             id: 1,
                             name: 'Flag A',
                             key: 'flag-a',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'non-existent-flag',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: ['non-existent-flag']
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           }
                         ])

      # Should return [nil, false] because dependency doesn't exist (falls back to remote)
      result, locally_evaluated = poller.get_feature_flag('flag-a', 'test-user', {}, {}, {}, true)
      expect(result).to be_nil
      expect(locally_evaluated).to be false
    end

    it 'evaluates complex dependency chains' do
      stub_feature_flags([
                           {
                             id: 1,
                             name: 'Flag A',
                             key: 'flag-a',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 2,
                             name: 'Flag B',
                             key: 'flag-b',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 3,
                             name: 'Flag C',
                             key: 'flag-c',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'flag-a',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: ['flag-a']
                                     },
                                     {
                                       key: 'flag-b',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: ['flag-b']
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 4,
                             name: 'Flag D',
                             key: 'flag-d',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'flag-c',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: %w[flag-a flag-b flag-c]
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           }
                         ])

      # All dependencies satisfied - should return True
      result, locally_evaluated = poller.get_feature_flag('flag-d', 'test-user', {}, {}, {}, true)
      expect(result).to be true
      expect(locally_evaluated).to be true

      # Make flag-a inactive - should break the chain
      flags = Marshal.load(Marshal.dump(poller.instance_variable_get(:@feature_flags)))
      flags[0][:active] = false
      stub_feature_flags(flags)

      result, locally_evaluated = poller.get_feature_flag('flag-d', 'test-user', {}, {}, {}, true)
      expect(result).to be false
      expect(locally_evaluated).to be true
    end

    it 'handles mixed conditions with flag dependency and property conditions' do
      stub_feature_flags([
                           {
                             id: 1,
                             name: 'Base Flag',
                             key: 'base-flag',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 2,
                             name: 'Mixed Flag',
                             key: 'mixed-flag',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'base-flag',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: ['base-flag']
                                     },
                                     {
                                       key: 'email',
                                       operator: 'icontains',
                                       value: '@example.com',
                                       type: 'person'
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           }
                         ])

      # Both flag dependency and email condition satisfied
      result, locally_evaluated = poller.get_feature_flag('mixed-flag', 'test-user',
                                                          {}, { 'email' => 'test@example.com' }, {}, true)
      expect(result).to be true
      expect(locally_evaluated).to be true

      # Flag dependency satisfied but email condition not satisfied
      result, locally_evaluated = poller.get_feature_flag('mixed-flag', 'test-user-2',
                                                          {}, { 'email' => 'test@other.com' }, {}, true)
      expect(result).to be false
      expect(locally_evaluated).to be true

      # Email condition satisfied but flag dependency not satisfied (base-flag inactive)
      flags = Marshal.load(Marshal.dump(poller.instance_variable_get(:@feature_flags)))
      flags[0][:active] = false
      stub_feature_flags(flags)

      result, locally_evaluated = poller.get_feature_flag('mixed-flag', 'test-user-3',
                                                          {}, { 'email' => 'test@example.com' }, {}, true)
      expect(result).to be false
      expect(locally_evaluated).to be true
    end

    it 'handles malformed dependency chains' do
      stub_feature_flags([
                           {
                             id: 1,
                             name: 'Base Flag',
                             key: 'base-flag',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 2,
                             name: 'Missing Chain Flag',
                             key: 'missing-chain-flag',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'base-flag',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag'
                                       # No dependency_chain property - should handle gracefully
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           }
                         ])

      property = { key: 'base-flag', operator: 'flag_evaluates_to', value: true, type: 'flag' }
      expect do
        poller.evaluate_flag_dependency(property, {}, 'test-user', {}, {})
      end.to raise_error(PostHog::InconclusiveMatchError, /missing required 'dependency_chain'/)
      expect(poller.evaluate_flag_dependency(
               property.merge(dependency_chain: ['base-flag']), {}, 'test-user', {}, {}
             )).to be(true)

      result, locally_evaluated = poller.get_feature_flag('missing-chain-flag', 'test-user', {}, {}, {}, true)
      expect(result).to be_nil
      expect(locally_evaluated).to be false
    end

    it 'handles inactive flags in dependency chain' do
      stub_feature_flags([
                           {
                             id: 1,
                             name: 'Inactive Base Flag',
                             key: 'inactive-base-flag',
                             active: false, # This flag is inactive
                             filters: {
                               groups: [
                                 {
                                   properties: [],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 2,
                             name: 'Dependent Flag',
                             key: 'dependent-flag',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'inactive-base-flag',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: ['inactive-base-flag']
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           }
                         ])

      # Should return false because dependency is inactive
      result, locally_evaluated = poller.get_feature_flag('dependent-flag', 'test-user', {}, {}, {}, true)
      expect(result).to be false
      expect(locally_evaluated).to be true
    end

    it 'evaluates multiple flag dependencies in AND condition' do
      stub_feature_flags([
                           {
                             id: 1,
                             name: 'Flag A',
                             key: 'flag-a',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 2,
                             name: 'Flag B',
                             key: 'flag-b',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           },
                           {
                             id: 3,
                             name: 'Multi Dependency Flag',
                             key: 'multi-dependency-flag',
                             active: true,
                             filters: {
                               groups: [
                                 {
                                   properties: [
                                     {
                                       key: 'flag-a',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: ['flag-a']
                                     },
                                     {
                                       key: 'flag-b',
                                       operator: 'flag_evaluates_to',
                                       value: true,
                                       type: 'flag',
                                       dependency_chain: ['flag-b']
                                     }
                                   ],
                                   rollout_percentage: 100
                                 }
                               ]
                             }
                           }
                         ])

      # Both dependencies satisfied
      result, locally_evaluated = poller.get_feature_flag('multi-dependency-flag', 'test-user', {}, {}, {}, true)
      expect(result).to be true
      expect(locally_evaluated).to be true

      # Make one dependency inactive - should fail AND condition
      flags = Marshal.load(Marshal.dump(poller.instance_variable_get(:@feature_flags)))
      flags[0][:active] = false # Make flag-a inactive
      stub_feature_flags(flags)

      result, locally_evaluated = poller.get_feature_flag('multi-dependency-flag', 'test-user', {}, {}, {}, true)
      expect(result).to be false
      expect(locally_evaluated).to be true
    end

    it 'evaluates production-style multivariate dependency chain' do
      flags = [
        {
          id: 451,
          name: 'Multivariate Leaf Flag (Base)',
          key: 'multivariate-leaf-flag',
          active: true,
          filters: {
            multivariate: {
              variants: [
                { key: 'pineapple', rollout_percentage: 25 },
                { key: 'mango', rollout_percentage: 25 },
                { key: 'papaya', rollout_percentage: 25 },
                { key: 'kiwi', rollout_percentage: 25 }
              ]
            },
            groups: [
              {
                variant: 'pineapple',
                properties: [
                  {
                    key: 'email',
                    type: 'person',
                    value: ['pineapple@example.com'],
                    operator: 'exact'
                  }
                ],
                rollout_percentage: 100
              },
              {
                variant: 'mango',
                properties: [
                  {
                    key: 'email',
                    type: 'person',
                    value: ['mango@example.com'],
                    operator: 'exact'
                  }
                ],
                rollout_percentage: 100
              },
              {
                variant: 'papaya',
                properties: [
                  {
                    key: 'email',
                    type: 'person',
                    value: ['papaya@example.com'],
                    operator: 'exact'
                  }
                ],
                rollout_percentage: 100
              },
              {
                variant: 'kiwi',
                properties: [
                  {
                    key: 'email',
                    type: 'person',
                    value: ['kiwi@example.com'],
                    operator: 'exact'
                  }
                ],
                rollout_percentage: 100
              },
              {
                properties: [],
                rollout_percentage: 0 # Force default to false for unknown emails
              }
            ]
          }
        },
        {
          id: 467,
          name: 'Multivariate Intermediate Flag (Depends on fruit)',
          key: 'multivariate-intermediate-flag',
          active: true,
          filters: {
            multivariate: {
              variants: [
                { key: 'blue', rollout_percentage: 100 }, # Force blue when dependency satisfied
                { key: 'red', rollout_percentage: 0 },
                { key: 'green', rollout_percentage: 0 },
                { key: 'black', rollout_percentage: 0 }
              ]
            },
            groups: [
              {
                variant: 'blue',
                properties: [
                  {
                    key: 'multivariate-leaf-flag',
                    type: 'flag',
                    value: 'pineapple',
                    operator: 'flag_evaluates_to',
                    dependency_chain: ['multivariate-leaf-flag']
                  }
                ],
                rollout_percentage: 100
              },
              {
                variant: 'red',
                properties: [
                  {
                    key: 'multivariate-leaf-flag',
                    type: 'flag',
                    value: 'mango',
                    operator: 'flag_evaluates_to',
                    dependency_chain: ['multivariate-leaf-flag']
                  }
                ],
                rollout_percentage: 100
              }
            ]
          }
        },
        {
          id: 468,
          name: 'Multivariate Root Flag (Depends on color)',
          key: 'multivariate-root-flag',
          active: true,
          filters: {
            multivariate: {
              variants: [
                { key: 'breaking-bad', rollout_percentage: 100 }, # Force breaking-bad when dependency satisfied
                { key: 'the-wire', rollout_percentage: 0 },
                { key: 'game-of-thrones', rollout_percentage: 0 },
                { key: 'the-expanse', rollout_percentage: 0 }
              ]
            },
            groups: [
              {
                variant: 'breaking-bad',
                properties: [
                  {
                    key: 'multivariate-intermediate-flag',
                    type: 'flag',
                    value: 'blue',
                    operator: 'flag_evaluates_to',
                    dependency_chain: %w[multivariate-leaf-flag multivariate-intermediate-flag]
                  }
                ],
                rollout_percentage: 100
              },
              {
                variant: 'the-wire',
                properties: [
                  {
                    key: 'multivariate-intermediate-flag',
                    type: 'flag',
                    value: 'red',
                    operator: 'flag_evaluates_to',
                    dependency_chain: %w[multivariate-leaf-flag multivariate-intermediate-flag]
                  }
                ],
                rollout_percentage: 100
              }
            ]
          }
        }
      ]

      stub_feature_flags(flags)

      # Test successful pineapple -> blue -> breaking-bad chain
      leaf_result, leaf_locally_evaluated = poller.get_feature_flag(
        'multivariate-leaf-flag', 'test-user',
        {}, { email: 'pineapple@example.com' },
        {}, true
      )

      intermediate_result, intermediate_locally_evaluated = poller.get_feature_flag(
        'multivariate-intermediate-flag', 'test-user',
        {}, { email: 'pineapple@example.com' },
        {}, true
      )
      root_result, root_locally_evaluated = poller.get_feature_flag(
        'multivariate-root-flag', 'test-user',
        {}, { email: 'pineapple@example.com' },
        {}, true
      )

      expect(leaf_result).to eq('pineapple')
      expect(leaf_locally_evaluated).to be true
      expect(intermediate_result).to eq('blue')
      expect(intermediate_locally_evaluated).to be true
      expect(root_result).to eq('breaking-bad')
      expect(root_locally_evaluated).to be true

      # Test successful mango -> red -> the-wire chain
      mango_leaf_result, mango_leaf_locally_evaluated = poller.get_feature_flag(
        'multivariate-leaf-flag', 'test-user',
        {}, { email: 'mango@example.com' },
        {}, true
      )
      mango_intermediate_result, mango_intermediate_locally_evaluated = poller.get_feature_flag(
        'multivariate-intermediate-flag', 'test-user',
        {}, { email: 'mango@example.com' },
        {}, true
      )
      mango_root_result, mango_root_locally_evaluated = poller.get_feature_flag(
        'multivariate-root-flag', 'test-user',
        {}, { email: 'mango@example.com' },
        {}, true
      )

      expect(mango_leaf_result).to eq('mango')
      expect(mango_leaf_locally_evaluated).to be true
      expect(mango_intermediate_result).to eq('red')
      expect(mango_intermediate_locally_evaluated).to be true
      expect(mango_root_result).to eq('the-wire')
      expect(mango_root_locally_evaluated).to be true

      # Test broken chain - user without matching email gets default/false results
      unknown_leaf_result, unknown_leaf_locally_evaluated = poller.get_feature_flag(
        'multivariate-leaf-flag', 'test-user',
        {}, { email: 'unknown@example.com' },
        {}, true
      )
      unknown_intermediate_result, unknown_intermediate_locally_evaluated = poller.get_feature_flag(
        'multivariate-intermediate-flag', 'test-user',
        {}, { email: 'unknown@example.com' },
        {}, true
      )
      unknown_root_result, unknown_root_locally_evaluated = poller.get_feature_flag(
        'multivariate-root-flag', 'test-user',
        {}, { email: 'unknown@example.com' },
        {}, true
      )

      expect(unknown_leaf_result).to be false # No matching email -> null variant -> false
      expect(unknown_leaf_locally_evaluated).to be true
      expect(unknown_intermediate_result).to be false # Dependency not satisfied
      expect(unknown_intermediate_locally_evaluated).to be true
      expect(unknown_root_result).to be false # Chain broken
      expect(unknown_root_locally_evaluated).to be true
    end

    def stub_feature_flags(flags)
      poller._apply_flag_definitions(flags: flags)
    end
  end

  describe 'FeatureFlagsPoller#condition_match' do
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }
    let(:flag) { { key: 'test-flag' } }
    let(:distinct_id) { 'test-user' }
    let(:properties) { { email: 'test@example.com' } }
    let(:evaluation_cache) { {} }
    let(:cohort_properties) { {} }

    before do
      # Stub the initial feature flag definitions request
      stub_request(:get, 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true')
        .to_return(status: 200, body: { flags: [] }.to_json)
    end

    context 'when rollout_percentage is 0' do
      let(:condition) { { properties: [], rollout_percentage: 0 } }

      it 'returns false' do
        result = poller.send(:condition_match, flag, distinct_id, condition, properties, evaluation_cache,
                             cohort_properties)
        expect(result).to be false
      end
    end

    context 'when rollout_percentage is nil and no properties' do
      let(:condition) { { properties: [], rollout_percentage: nil } }

      it 'returns true' do
        result = poller.send(:condition_match, flag, distinct_id, condition, properties, evaluation_cache,
                             cohort_properties)
        expect(result).to be true
      end
    end

    context 'when rollout_percentage is nil and properties exist' do
      let(:condition) do
        {
          properties: [{ key: 'email', value: 'test@example.com', operator: 'exact' }],
          rollout_percentage: nil
        }
      end

      before do
        allow(PostHog::FeatureFlagsPoller).to receive(:match_property).and_return(true)
      end

      it 'returns true when all properties match' do
        result = poller.send(:condition_match, flag, distinct_id, condition, properties, evaluation_cache,
                             cohort_properties)
        expect(result).to be true
      end
    end

    context 'when properties exist but not all match' do
      let(:condition) do
        {
          properties: [{ key: 'email', value: 'other@example.com', operator: 'exact' }],
          rollout_percentage: nil
        }
      end

      before do
        allow(PostHog::FeatureFlagsPoller).to receive(:match_property).and_return(false)
      end

      it 'returns false' do
        result = poller.send(:condition_match, flag, distinct_id, condition, properties, evaluation_cache,
                             cohort_properties)
        expect(result).to be false
      end
    end

    context 'when rollout_percentage is 50' do
      let(:condition) { { properties: [], rollout_percentage: 50 } }

      context 'when hash is below threshold' do
        before do
          allow(poller).to receive(:_hash).and_return(0.3)
        end

        it 'returns true' do
          result = poller.send(:condition_match, flag, distinct_id, condition, properties, evaluation_cache,
                               cohort_properties)
          expect(result).to be true
        end
      end

      context 'when hash is above threshold' do
        before do
          allow(poller).to receive(:_hash).and_return(0.7)
        end

        it 'returns false' do
          result = poller.send(:condition_match, flag, distinct_id, condition, properties, evaluation_cache,
                               cohort_properties)
          expect(result).to be false
        end
      end
    end
  end

  describe 'FeatureFlagsPoller#match_feature_flag_properties early_exit' do
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }
    let(:distinct_id) { 'test-user' }
    let(:properties) { { email: 'test@example.com' } }
    let(:evaluation_cache) { {} }

    before do
      # Stub the initial feature flag definitions request
      stub_request(:get, 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true')
        .to_return(status: 200, body: { flags: [] }.to_json)
    end

    # First group: properties match (none) but rollout 0% excludes the user
    # (OUT_OF_ROLLOUT_BOUND). Second group: properties match and rollout 100%
    # includes the user (would MATCH).
    def build_flag(early_exit:)
      filters = {
        groups: [
          { properties: [], rollout_percentage: 0 },
          { properties: [], rollout_percentage: 100 }
        ]
      }
      filters[:early_exit] = early_exit unless early_exit.nil?
      { key: 'test-flag', filters: filters }
    end

    [
      [true,  false, 'enabled'],
      [nil,   true,  'unset'],
      [false, true,  'explicitly false']
    ].each do |early_exit_val, expected, description|
      context "when early_exit is #{description}" do
        it "returns #{expected}" do
          flag = build_flag(early_exit: early_exit_val)
          result = poller.send(:match_feature_flag_properties, flag, distinct_id, properties, evaluation_cache)
          expect(result).to be expected
        end
      end
    end

    context 'when a group fails on a property filter (not rollout) and early_exit is enabled' do
      it 'does not early-exit and falls through to a later matching group' do
        flag = {
          key: 'test-flag',
          filters: {
            early_exit: true,
            groups: [
              # Property filter does NOT match -> NO_MATCH (must fall through
              # even with early_exit enabled), despite rollout 0%.
              {
                properties: [{ key: 'email', value: 'other@example.com', operator: 'exact', type: 'person' }],
                rollout_percentage: 0
              },
              { properties: [], rollout_percentage: 100 }
            ]
          }
        }
        result = poller.send(:match_feature_flag_properties, flag, distinct_id, properties, evaluation_cache)
        expect(result).to be true
      end
    end

    context 'when early_exit is enabled on a multivariate flag' do
      it 'returns false without leaking a variant from a later group' do
        flag = {
          key: 'mv-flag',
          filters: {
            early_exit: true,
            multivariate: { variants: [{ key: 'control', rollout_percentage: 100 }] },
            groups: [
              { properties: [], rollout_percentage: 0 },
              { properties: [], rollout_percentage: 100 }
            ]
          }
        }
        result = poller.send(:match_feature_flag_properties, flag, distinct_id, properties, evaluation_cache)
        expect(result).to be false
      end
    end
  end

  describe 'FeatureFlagsPoller ETag support' do
    let(:feature_flag_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }

    describe 'load_feature_flags with ETag support' do
      it 'stores ETag from initial response' do
        stub_request(:get, feature_flag_endpoint)
          .to_return(
            status: 200,
            body: { flags: [{ id: 1, key: 'beta-feature', active: true }], group_type_mapping: {},
                    cohorts: {} }.to_json,
            headers: { 'ETag' => '"abc123"' }
          )

        poller.load_feature_flags(true)

        expect(poller.instance_variable_get(:@flags_etag).value).to eq('"abc123"')
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(1)
      end

      it 'sends If-None-Match header on subsequent requests' do
        # Use response sequence - first response without If-None-Match check, second with
        beta_flags = { flags: [{ id: 1, key: 'beta-feature', active: true }],
                       group_type_mapping: {}, cohorts: {} }
        new_flags = { flags: [{ id: 1, key: 'new-feature', active: true }],
                      group_type_mapping: {}, cohorts: {} }
        stub_request(:get, feature_flag_endpoint)
          .to_return(
            { status: 200, body: beta_flags.to_json, headers: { 'ETag' => '"initial-etag"' } },
            { status: 200, body: new_flags.to_json, headers: { 'ETag' => '"new-etag"' } }
          )

        poller.load_feature_flags(true)
        poller.load_feature_flags(true)

        expect(WebMock).to have_requested(:get, feature_flag_endpoint)
          .with(headers: { 'If-None-Match' => '"initial-etag"' }).once
      end

      it 'handles 304 Not Modified response and preserves cached flags' do
        beta_flags = { flags: [{ id: 1, key: 'beta-feature', active: true }],
                       group_type_mapping: { '0' => 'company' }, cohorts: {} }
        stub_request(:get, feature_flag_endpoint)
          .to_return(
            { status: 200, body: beta_flags.to_json, headers: { 'ETag' => '"test-etag"' } },
            { status: 304, body: '', headers: { 'ETag' => '"test-etag"' } }
          )

        poller.load_feature_flags(true)

        # Verify initial flags are loaded
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(1)
        expect(poller.instance_variable_get(:@feature_flags)[0][:key]).to eq('beta-feature')
        # The JSON parser symbolizes keys, so compare with symbol keys
        expect(poller.instance_variable_get(:@group_type_mapping)).to eq({ '0': 'company' })

        poller.load_feature_flags(true)

        # Flags should still be the same (not cleared)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(1)
        expect(poller.instance_variable_get(:@feature_flags)[0][:key]).to eq('beta-feature')
        expect(poller.instance_variable_get(:@group_type_mapping)).to eq({ '0': 'company' })
      end

      it 'preserves the minimal_flag_called_events gate across a 304 Not Modified response' do
        beta_flags = { flags: [{ id: 1, key: 'beta-feature', active: true }],
                       group_type_mapping: {}, cohorts: {}, minimal_flag_called_events: true }
        stub_request(:get, feature_flag_endpoint)
          .to_return(
            { status: 200, body: beta_flags.to_json, headers: { 'ETag' => '"test-etag"' } },
            { status: 304, body: '', headers: { 'ETag' => '"test-etag"' } }
          )

        poller.load_feature_flags(true)
        expect(poller.minimal_flag_called_events).to be(true)

        poller.load_feature_flags(true)

        expect(poller.minimal_flag_called_events).to be(true)
      end

      it 'updates ETag when flags change' do
        # Need 3 responses: 1 for client initialization, 2 for the test
        empty_flags = { flags: [], group_type_mapping: {}, cohorts: {} }
        flag_v1 = { flags: [{ id: 1, key: 'flag-v1', active: true }],
                    group_type_mapping: {}, cohorts: {} }
        flag_v2 = { flags: [{ id: 1, key: 'flag-v2', active: true }],
                    group_type_mapping: {}, cohorts: {} }
        stub_request(:get, feature_flag_endpoint)
          .to_return(
            { status: 200, body: empty_flags.to_json },
            { status: 200, body: flag_v1.to_json, headers: { 'ETag' => '"etag-v1"' } },
            { status: 200, body: flag_v2.to_json, headers: { 'ETag' => '"etag-v2"' } }
          )

        poller.load_feature_flags(true)
        expect(poller.instance_variable_get(:@flags_etag).value).to eq('"etag-v1"')

        poller.load_feature_flags(true)

        expect(poller.instance_variable_get(:@flags_etag).value).to eq('"etag-v2"')
        expect(poller.instance_variable_get(:@feature_flags)[0][:key]).to eq('flag-v2')
      end

      it 'clears ETag when server stops sending it' do
        # Need 3 responses: 1 for client initialization, 2 for the test
        empty_flags = { flags: [], group_type_mapping: {}, cohorts: {} }
        flag_v1 = { flags: [{ id: 1, key: 'flag-v1', active: true }],
                    group_type_mapping: {}, cohorts: {} }
        flag_v2 = { flags: [{ id: 1, key: 'flag-v2', active: true }],
                    group_type_mapping: {}, cohorts: {} }
        stub_request(:get, feature_flag_endpoint)
          .to_return(
            { status: 200, body: empty_flags.to_json },
            { status: 200, body: flag_v1.to_json, headers: { 'ETag' => '"etag-v1"' } },
            { status: 200, body: flag_v2.to_json }
          )

        poller.load_feature_flags(true)
        expect(poller.instance_variable_get(:@flags_etag).value).to eq('"etag-v1"')

        poller.load_feature_flags(true)

        expect(poller.instance_variable_get(:@flags_etag).value).to be_nil
        expect(poller.instance_variable_get(:@feature_flags)[0][:key]).to eq('flag-v2')
      end

      it 'handles 304 without ETag header and preserves existing ETag' do
        beta_flags = { flags: [{ id: 1, key: 'beta-feature', active: true }],
                       group_type_mapping: {}, cohorts: {} }
        stub_request(:get, feature_flag_endpoint)
          .to_return(
            { status: 200, body: beta_flags.to_json, headers: { 'ETag' => '"original-etag"' } },
            { status: 304, body: '' }
          )

        poller.load_feature_flags(true)

        poller.load_feature_flags(true)

        # ETag should be preserved since server returned 304 (even without new ETag)
        expect(poller.instance_variable_get(:@flags_etag).value).to eq('"original-etag"')
        # And flags should be preserved
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(1)
      end

      it 'updates ETag when 304 response includes a new ETag' do
        # Need 3 responses: 1 for client initialization, 2 for the test
        empty_flags = { flags: [], group_type_mapping: {}, cohorts: {} }
        beta_flags = { flags: [{ id: 1, key: 'beta-feature', active: true }],
                       group_type_mapping: {}, cohorts: {} }
        stub_request(:get, feature_flag_endpoint)
          .to_return(
            { status: 200, body: empty_flags.to_json },
            { status: 200, body: beta_flags.to_json, headers: { 'ETag' => '"original-etag"' } },
            { status: 304, body: '', headers: { 'ETag' => '"updated-etag"' } }
          )

        poller.load_feature_flags(true)
        expect(poller.instance_variable_get(:@flags_etag).value).to eq('"original-etag"')

        poller.load_feature_flags(true)

        # ETag should be updated to the new value from 304 response
        expect(poller.instance_variable_get(:@flags_etag).value).to eq('"updated-etag"')
        # And flags should be preserved
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(1)
      end

      it 'preserves ETag when server returns an error response' do
        # Need 3 responses: 1 for client initialization, 2 for the test
        empty_flags = { flags: [], group_type_mapping: {}, cohorts: {} }
        beta_flags = { flags: [{ id: 1, key: 'beta-feature', active: true }],
                       group_type_mapping: {}, cohorts: {} }
        stub_request(:get, feature_flag_endpoint)
          .to_return(
            { status: 200, body: empty_flags.to_json },
            { status: 200, body: beta_flags.to_json, headers: { 'ETag' => '"original-etag"' } },
            { status: 500, body: { error: 'Internal Server Error' }.to_json }
          )

        poller.load_feature_flags(true)
        expect(poller.instance_variable_get(:@flags_etag).value).to eq('"original-etag"')

        poller.load_feature_flags(true)

        # ETag should be preserved since the 500 error doesn't contain valid flag data
        expect(poller.instance_variable_get(:@flags_etag).value).to eq('"original-etag"')
        # And flags should be preserved from previous successful load
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(1)
        expect(poller.instance_variable_get(:@feature_flags)[0][:key]).to eq('beta-feature')
      end
    end

    describe '_mask_tokens_in_url' do
      before do
        # Stub the initial feature flag definitions request made during client initialization
        stub_request(:get, feature_flag_endpoint)
          .to_return(status: 200, body: { flags: [] }.to_json)
      end

      it 'masks token keeping first 10 chars visible' do
        url = 'https://example.com/api/flags?token=phc_abc123xyz789&send_cohorts'
        result = poller.send(:_mask_tokens_in_url, url)
        expect(result).to eq('https://example.com/api/flags?token=phc_abc123...&send_cohorts')
      end

      it 'masks token at end of URL' do
        url = 'https://example.com/api/flags?token=phc_abc123xyz789'
        result = poller.send(:_mask_tokens_in_url, url)
        expect(result).to eq('https://example.com/api/flags?token=phc_abc123...')
      end

      it 'leaves URLs without token unchanged' do
        url = 'https://example.com/api/flags?other=value'
        result = poller.send(:_mask_tokens_in_url, url)
        expect(result).to eq('https://example.com/api/flags?other=value')
      end

      it 'leaves short tokens (<10 chars) unchanged' do
        url = 'https://example.com/api/flags?token=short'
        result = poller.send(:_mask_tokens_in_url, url)
        expect(result).to eq('https://example.com/api/flags?token=short')
      end

      it 'masks exactly 10 char tokens' do
        url = 'https://example.com/api/flags?token=1234567890'
        result = poller.send(:_mask_tokens_in_url, url)
        expect(result).to eq('https://example.com/api/flags?token=1234567890...')
      end
    end
  end

  describe 'Unresolved flag reasons' do
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }
    let(:plan_is_pro) { { key: 'plan', operator: 'exact', value: 'pro', type: 'person' } }
    let(:plan_is_free) { { key: 'plan', operator: 'exact', value: 'free', type: 'person' } }
    let(:email_is_set) { { key: 'email', operator: 'is_set', type: 'person' } }
    let(:unknown_operator) { { key: 'plan', operator: 'bogus', value: 'x', type: 'person' } }
    let(:static_cohort) { { key: 'id', value: 42, type: 'cohort' } }

    before do
      stub_request(:get, 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true')
        .to_return(status: 200, body: { flags: [] }.to_json)
    end

    def flag(key, *conditions, **extra)
      {
        key: key, active: true,
        filters: { groups: conditions.map { |properties| { properties: properties, rollout_percentage: 100 } } }
      }.merge(extra)
    end

    def depends_on(key)
      { key: key, type: 'flag', value: true, operator: 'flag_evaluates_to', dependency_chain: [key] }
    end

    def evaluate(flag, properties, flags: [], cohorts: {}, **options)
      poller._apply_flag_definitions(flags: [flag, *flags], cohorts: cohorts)
      snapshot = poller._evaluation_snapshot
      poller.match_feature_flag_properties(snapshot[:flags_by_key][flag[:key]], 'user-123', properties, {},
                                           snapshot[:cohorts], **options)
    end

    def expect_unresolved(error_class, reason, &block)
      expect(&block).to raise_error(error_class) { |error| expect(error.reason).to eq(reason) }
    end

    it 'defaults the reason of both errors to unsupported_definition' do
      expect(InconclusiveMatchError.new('message').reason).to eq(UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      expect(RequiresServerEvaluation.new('message').reason).to eq(UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      expect(InconclusiveMatchError.new('message', reason: UnresolvedFlagReason::MISSING_CONTEXT).message)
        .to eq('message')
    end

    [
      [nil, UnresolvedFlagReason::EXPERIENCE_CONTINUITY, UnresolvedFlagReason::EXPERIENCE_CONTINUITY],
      [UnresolvedFlagReason::MISSING_CONTEXT, UnresolvedFlagReason::UNSUPPORTED_DEFINITION,
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      [UnresolvedFlagReason::MISSING_CONTEXT, UnresolvedFlagReason::UNRESOLVED_DEPENDENCY,
       UnresolvedFlagReason::UNRESOLVED_DEPENDENCY],
      [UnresolvedFlagReason::UNSUPPORTED_DEFINITION, UnresolvedFlagReason::UNRESOLVED_DEPENDENCY,
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      [UnresolvedFlagReason::EXPERIENCE_CONTINUITY, UnresolvedFlagReason::UNSUPPORTED_DEFINITION,
       UnresolvedFlagReason::EXPERIENCE_CONTINUITY]
    ].each do |current, reason, expected|
      it "keeps #{expected} when #{reason.inspect} follows #{current.inspect}" do
        expect(FeatureFlagsPoller.pick_unresolved_reason(current, reason)).to eq(expected)
      end
    end

    [
      ['a missing property', 'exact', 'x', {}, UnresolvedFlagReason::MISSING_CONTEXT],
      ['an unknown operator', 'bogus', 'x', { key: 'x' }, UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an unknown operator and a missing property', 'bogus', 'x', {}, UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid numeric filter', 'gt', 'abc', { key: 5 }, UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid numeric filter and a missing property', 'gt', 'abc', {},
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid date filter', 'is_date_before', 'not-a-date', { key: '2024-01-01' },
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['a boolean date filter', 'is_date_after', true, { key: '2024-01-01' },
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid context date', 'is_date_before', '2024-01-01', { key: 'not-a-date' },
       UnresolvedFlagReason::MISSING_CONTEXT],
      ['an invalid date filter and context', 'is_date_after', 'not-a-date', { key: 'nope' },
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid semver filter', 'semver_gt', 'x.y', { key: '1.2.3' }, UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid context semver', 'semver_gt', '1.2.3', { key: 'x.y' }, UnresolvedFlagReason::MISSING_CONTEXT],
      ['an invalid semver filter and context', 'semver_gt', 'x.y', { key: 'a.b' },
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid semver filter and a missing property', 'semver_gt', 'x.y', {},
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid wildcard filter', 'semver_wildcard', '1x.*', { key: '1.8.0' },
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid wildcard filter and context', 'semver_wildcard', '1x.*', { key: 'a.b' },
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['an invalid context semver for a range', 'semver_tilde', '1.2.3', { key: 'x' },
       UnresolvedFlagReason::MISSING_CONTEXT],
      ['a regex the server must evaluate', 'regex', '\bfoo', { key: 'foo' }, UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['a regex the server must evaluate and a missing property', 'regex', '\bfoo', {},
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['a regex the server must evaluate for the context value', 'regex', '\w+', { key: 'é' },
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['a regex with an invalid byte and a missing property', 'regex', "\\\xFF", {},
       UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
      ['a portable regex and a missing property', 'regex', 'foo', {}, UnresolvedFlagReason::MISSING_CONTEXT]
    ].each do |cause, operator, value, property_values, reason|
      it "reports #{reason} for #{cause}" do
        property = { key: 'key', operator: operator, value: value }

        expect_unresolved(InconclusiveMatchError, reason) do
          FeatureFlagsPoller.match_property(property, property_values)
        end
      end
    end

    [
      ['a missing property first', :email_is_set, :plan_is_free],
      ['a missing property last', :plan_is_free, :email_is_set],
      ['a static cohort first', :static_cohort, :plan_is_free],
      ['an unknown operator first', :unknown_operator, :plan_is_free]
    ].each do |description, first, second|
      it "rules a condition out when a filter does not match, with #{description}" do
        checkout = flag('checkout', [send(first), send(second)])

        expect(evaluate(checkout, { plan: 'pro' })).to be(false)
        expect { evaluate(checkout, { plan: 'free' }) }.to(raise_error do |error|
          expect(error).to be_a(InconclusiveMatchError).or be_a(RequiresServerEvaluation)
        end)
      end
    end

    it 'lets a later condition resolve when an unexpected error follows a filter that cannot be checked' do
      keyless_filter = { operator: 'exact', value: 'x', type: 'person' }

      expect(evaluate(flag('checkout', [email_is_set, keyless_filter], []), {})).to be(true)
      expect { evaluate(flag('checkout', [keyless_filter], []), {}) }.to raise_error(NoMethodError)
    end

    it 'reports the highest-precedence reason of a condition' do
      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
        evaluate(flag('checkout', [plan_is_pro, unknown_operator]), {})
      end
    end

    it 'requires the server when a static cohort is the first filter that cannot be checked' do
      expect_unresolved(RequiresServerEvaluation, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
        evaluate(flag('checkout', [static_cohort, plan_is_pro]), {})
      end
    end

    it 'lets later conditions resolve when a static cohort follows a filter that cannot be checked' do
      checkout = flag('checkout', [plan_is_pro, static_cohort], [email_is_set])

      expect(evaluate(checkout, { email: 'a@b.c' })).to be(true)
      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
        evaluate(checkout, {})
      end
    end

    it 'keeps the static cohort reason when a later condition requires the server' do
      expect_unresolved(RequiresServerEvaluation, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
        evaluate(flag('checkout', [plan_is_pro], [static_cohort]), {})
      end
    end

    it 'reports a dependency that requires the server as unresolved_dependency' do
      base = flag('base', [static_cohort])

      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNRESOLVED_DEPENDENCY) do
        evaluate(flag('checkout', [depends_on('base')]), {}, flags: [base])
      end
      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
        evaluate(flag('checkout', [unknown_operator], [depends_on('base')]), { plan: 'pro' }, flags: [base])
      end
    end

    it 'reports a dependency with experience continuity as unresolved_dependency' do
      base = flag('base', [], ensure_experience_continuity: true)

      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNRESOLVED_DEPENDENCY) do
        evaluate(flag('checkout', [depends_on('base')]), {}, flags: [base])
      end
    end

    it 'resolves an inactive dependency with experience continuity as false' do
      base = flag('base', [], active: false, ensure_experience_continuity: true)

      expect(evaluate(flag('checkout', [depends_on('base')]), {}, flags: [base])).to be(false)
    end

    it 'reports a missing dependency before an inconclusive one earlier in the chain' do
      dependency = depends_on('missing').merge(dependency_chain: %w[base missing])

      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
        evaluate(flag('checkout', [dependency]), {}, flags: [flag('base', [plan_is_pro])])
      end
    end

    it 'reports a missing dependency the same way on a later lookup' do
      evaluation_cache = {}

      2.times do
        expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
          poller.evaluate_flag_dependency(depends_on('missing'), evaluation_cache, 'user-123', {}, {})
        end
      end
      expect(evaluation_cache).to eq({})
    end

    [['a circular chain', []], ['a chain that is not a list', nil]].each do |description, dependency_chain|
      it "reports #{description} as unsupported_definition" do
        dependency = depends_on('base').merge(dependency_chain: dependency_chain)

        expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
          evaluate(flag('checkout', [dependency]), {}, flags: [flag('base', [])])
        end
      end
    end

    it 'reports missing group properties as missing_context' do
      checkout = flag('checkout', [])
      checkout[:filters][:groups][0][:aggregation_group_type_index] = 0
      poller._apply_flag_definitions(flags: [checkout], group_type_mapping: { '0' => 'company' })
      snapshot = poller._evaluation_snapshot

      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::MISSING_CONTEXT) do
        poller.match_feature_flag_properties(snapshot[:flags_by_key]['checkout'], 'user-123', {}, {}, {},
                                             groups: { company: 'acme' }, group_properties: {})
      end
    end

    it 'reports the highest-precedence reason of a cohort property group' do
      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
        FeatureFlagsPoller.match_property_group({ type: 'AND', values: [plan_is_pro, unknown_operator] }, {}, {})
      end
    end

    it 'resolves a nested cohort property group when another group decides it' do
      inconclusive_group = { type: 'AND', values: [plan_is_pro] }
      country_group = { type: 'AND', values: [{ key: 'country', operator: 'exact', value: 'US' }] }

      expect(FeatureFlagsPoller.match_property_group(
               { type: 'AND', values: [inconclusive_group, country_group] }, { country: 'CA' }, {}
             )).to be(false)
      expect(FeatureFlagsPoller.match_property_group(
               { type: 'OR', values: [inconclusive_group, country_group] }, { country: 'US' }, {}
             )).to be(true)
      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::MISSING_CONTEXT) do
        FeatureFlagsPoller.match_property_group({ type: 'OR', values: [inconclusive_group, country_group] },
                                                { country: 'CA' }, {})
      end
    end

    it 'resolves an inactive flag with experience continuity as false' do
      checkout = flag('checkout', [static_cohort], active: false, ensure_experience_continuity: true)

      expect(poller._compute_flag_locally(checkout, 'user-123')).to be(false)
      expect_unresolved(RequiresServerEvaluation, UnresolvedFlagReason::EXPERIENCE_CONTINUITY) do
        poller._compute_flag_locally(checkout.merge(active: true), 'user-123')
      end
    end

    it 'reports an unknown group type as unsupported_definition' do
      checkout = flag('checkout', [])
      checkout[:filters][:aggregation_group_type_index] = 9

      expect_unresolved(InconclusiveMatchError, UnresolvedFlagReason::UNSUPPORTED_DEFINITION) do
        poller._compute_flag_locally(checkout, 'user-123', { company: 'acme' })
      end
    end

    describe '.definition_unresolved_reason' do
      let(:country_is_us) { { key: 'country', operator: 'exact', value: 'US', type: 'person' } }
      let(:cohorts) do
        {
          '1': { type: 'OR', values: [static_cohort] },
          '2': { type: 'OR', values: [{ type: 'AND', values: [country_is_us] }] },
          '3': { type: 'OR', values: [{ type: 'AND', values: [static_cohort] }] }
        }
      end

      {
        'a resolvable flag' => [-> { flag('checkout', [plan_is_pro]) }, nil],
        'an inactive flag' => [-> { flag('checkout', [static_cohort], active: false) }, nil],
        'experience continuity' => [
          -> { flag('checkout', [static_cohort], ensure_experience_continuity: true) },
          UnresolvedFlagReason::EXPERIENCE_CONTINUITY
        ],
        'a static cohort' => [
          -> { flag('checkout', [plan_is_pro], [static_cohort]) }, UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        ],
        'a static cohort nested in a cohort' => [
          -> { flag('checkout', [{ key: 'id', value: 1, type: 'cohort' }]) },
          UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        ],
        'a dynamic cohort' => [-> { flag('checkout', [{ key: 'id', value: 2, type: 'cohort' }]) }, nil],
        'a static cohort in a nested cohort group' => [
          -> { flag('checkout', [{ key: 'id', value: 3, type: 'cohort' }]) },
          UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        ],
        'an unknown operator' => [-> { flag('checkout', [unknown_operator]) }, UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
        'a malformed value' => [
          -> { flag('checkout', [{ key: 'n', operator: 'gt', value: 'abc', type: 'person' }]) },
          UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        ],
        'a regex the server must evaluate' => [
          -> { flag('checkout', [{ key: 'email', operator: 'regex', value: '\bfoo', type: 'person' }]) },
          UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        ],
        'a missing dependency' => [
          -> { flag('checkout', [depends_on('missing')]) }, UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        ],
        'a circular dependency' => [
          -> { flag('checkout', [depends_on('checkout').merge(dependency_chain: [])]) },
          UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        ],
        'a dependency with a loaded definition' => [-> { flag('checkout', [depends_on('checkout')]) }, nil],
        'an unknown group type' => [
          -> { flag('checkout', []).merge(filters: { aggregation_group_type_index: 9, groups: [] }) },
          UnresolvedFlagReason::UNSUPPORTED_DEFINITION
        ],
        'a known group type' => [
          -> { flag('checkout', []).merge(filters: { aggregation_group_type_index: 0, groups: [] }) }, nil
        ]
      }.each do |description, (build_flag, expected)|
        it "returns #{expected.inspect} for #{description}" do
          checkout = instance_exec(&build_flag)

          expect(FeatureFlagsPoller.definition_unresolved_reason(checkout, { 'checkout' => checkout }, cohorts,
                                                                 { '0': 'company' })).to eq(expected)
        end
      end
    end
  end

  # Mirrors the @unresolvable_flag_warning_capable scenarios of the evaluate-flags spec.
  describe 'Unresolvable flag warning' do
    let(:feature_flag_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:log) { StringIO.new }
    let(:checkout) do
      { id: 1, key: 'checkout', active: true, ensure_experience_continuity: true,
        filters: { groups: [{ properties: [], rollout_percentage: 100 }] } }
    end
    let(:beta_ui) do
      { id: 2, key: 'beta-ui', active: true, filters: { groups: [{ properties: [], rollout_percentage: 100 }] } }
    end

    before do
      # Same level as the default SDK logger, so these warnings show without debug logging.
      PostHog::Logging.logger = Logger.new(log, level: Logger::WARN)
    end

    def definitions(*flags)
      { flags: flags, group_type_mapping: {}, cohorts: {} }.to_json
    end

    def refresh_with(*responses)
      stub_request(:get, feature_flag_endpoint).to_return(*responses)
      client = Client.new(api_key: API_KEY, secret_key: API_KEY, test_mode: true)
      poller = client.instance_variable_get(:@feature_flags_poller)
      (responses.length - 1).times { poller.load_feature_flags(true) }
      poller
    end

    def warnings(key, reason)
      log.string.lines.select { |line| line.include?(key) && line.include?("(reason: #{reason})") }
    end

    {
      'unchanged definitions' => lambda {
        refresh_with({ status: 200, body: definitions(checkout, beta_ui), headers: { 'ETag' => '"1"' } },
                     { status: 200, body: definitions(checkout, beta_ui), headers: { 'ETag' => '"2"' } })
      },
      '304 not modified' => lambda {
        refresh_with({ status: 200, body: definitions(checkout, beta_ui), headers: { 'ETag' => '"1"' } },
                     { status: 304, body: '', headers: { 'ETag' => '"1"' } })
      },
      'unchanged definitions with reordered keys' => lambda {
        refresh_with({ status: 200, body: definitions(checkout, beta_ui) },
                     { status: 200, body: definitions(checkout.to_a.reverse.to_h, beta_ui) })
      },
      'successful shared-cache load' => lambda {
        provider = double(
          'cache provider',
          flag_definitions: JSON.parse(definitions(checkout, beta_ui)),
          should_fetch_flag_definitions?: false, on_flag_definitions_received: nil, shutdown: nil
        )
        client = Client.new(api_key: API_KEY, secret_key: API_KEY, test_mode: true,
                            flag_definition_cache_provider: provider)
        client.instance_variable_get(:@feature_flags_poller).load_feature_flags(true)
      }
    }.each do |refresh_result, refresh|
      it "logs one warning for a flag local evaluation never resolves after #{refresh_result}" do
        instance_exec(&refresh)

        logged = warnings('checkout', UnresolvedFlagReason::EXPERIENCE_CONTINUITY)
        expect(logged.length).to eq(1)
        expect(logged.first).to include('WARN')
        expect(logged.first).not_to include('beta-ui')
        expect(WebMock).not_to have_requested(:post, 'https://us.i.posthog.com/flags/?v=2')
      end
    end

    it 'logs the warning again when the definition changes' do
      refresh_with({ status: 200, body: definitions(checkout) },
                   { status: 200, body: definitions(checkout.merge(id: 3)) })

      expect(warnings('checkout', UnresolvedFlagReason::EXPERIENCE_CONTINUITY).length).to eq(2)
      expect(WebMock).not_to have_requested(:post, 'https://us.i.posthog.com/flags/?v=2')
    end

    it 'does not log the warning again when another flag changes' do
      refresh_with({ status: 200, body: definitions(checkout, beta_ui) },
                   { status: 200, body: definitions(checkout, beta_ui.merge(id: 3)) })

      expect(warnings('checkout', UnresolvedFlagReason::EXPERIENCE_CONTINUITY).length).to eq(1)
    end

    it 'forgets a removed flag and warns again when it returns' do
      poller = refresh_with({ status: 200, body: definitions(checkout) },
                            { status: 200, body: definitions(beta_ui) },
                            { status: 200, body: definitions(checkout) })

      expect(warnings('checkout', UnresolvedFlagReason::EXPERIENCE_CONTINUITY).length).to eq(2)
      expect(poller.instance_variable_get(:@warned_unresolvable_flags).keys).to eq(['checkout'])
    end

    {
      'a static cohort' => { key: 'id', value: 42, type: 'cohort' },
      'an unknown operator' => { key: 'plan', operator: 'bogus', value: 'x', type: 'person' },
      'a malformed value' => { key: 'since', operator: 'is_date_after', value: 'x', type: 'person' },
      'a missing dependency' => {
        key: 'missing', type: 'flag', value: true, operator: 'flag_evaluates_to', dependency_chain: ['missing']
      },
      'a circular dependency' => {
        key: 'checkout', type: 'flag', value: true, operator: 'flag_evaluates_to', dependency_chain: []
      }
    }.each do |cause, property|
      it "logs one unsupported_definition warning for #{cause}" do
        unsupported = { id: 1, key: 'checkout', active: true,
                        filters: { groups: [{ properties: [property], rollout_percentage: 100 }] } }

        refresh_with({ status: 200, body: definitions(unsupported) }, { status: 200, body: definitions(unsupported) })

        expect(warnings('checkout', UnresolvedFlagReason::UNSUPPORTED_DEFINITION).length).to eq(1)
      end
    end

    it 'logs one line per reason and none for flags that depend on the call' do
      flags = [
        checkout,
        checkout.merge(id: 3, key: 'inactive', active: false),
        beta_ui.merge(id: 4, key: 'needs-plan',
                      filters: { groups: [{ properties: [{ key: 'plan', value: 'pro', type: 'person' }] }] }),
        beta_ui.merge(id: 5, key: 'dependent', filters: { groups: [{ properties: [
                        { key: 'checkout', type: 'flag', value: true, operator: 'flag_evaluates_to',
                          dependency_chain: ['checkout'] }
                      ] }] }),
        beta_ui.merge(id: 6, key: 'static',
                      filters: { groups: [{ properties: [{ key: 'id', value: 42, type: 'cohort' }] }] })
      ]

      refresh_with({ status: 200, body: definitions(*flags) })

      expect(log.string.lines.length).to eq(2)
      expect(warnings('checkout', UnresolvedFlagReason::EXPERIENCE_CONTINUITY).length).to eq(1)
      expect(warnings('static', UnresolvedFlagReason::UNSUPPORTED_DEFINITION).length).to eq(1)
      %w[inactive needs-plan dependent].each { |key| expect(log.string).not_to include(key) }
    end
  end

  describe FeatureFlagsPoller do
    it 'applies open, read, and write timeouts to feature flag requests' do
      poller = described_class.allocate
      uri = URI('https://example.com/flags')
      request = Net::HTTP::Get.new(uri)
      response = double('response', code: '200', body: '{}')
      http = double('http', request: response)

      expect(Net::HTTP).to receive(:start).with(
        'example.com',
        443,
        use_ssl: true,
        open_timeout: 7,
        read_timeout: 7,
        write_timeout: 7
      ).and_yield(http)

      expect(poller.send(:_request, uri, request, 7)).to eq(status: 200)
    end
  end
end
