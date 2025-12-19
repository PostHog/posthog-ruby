# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe 'Feature Flag Error Tracking' do
    let(:flags_endpoint) { 'https://app.posthog.com/flags/?v=2' }
    let(:feature_flag_endpoint) { 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true' }
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }

    before do
      # Stub the initial feature flag definitions request
      stub_request(:get, feature_flag_endpoint)
        .to_return(status: 200, body: { flags: [] }.to_json)
    end

    describe '$feature_flag_error property' do
      context 'when flag is missing from response' do
        it 'adds flag_missing error to $feature_flag_called event' do
          # Mock response without the requested flag
          flags_response = {
            'featureFlags' => { 'other-flag' => true },
            'featureFlagPayloads' => {}
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          result = client.get_feature_flag('missing-flag', 'test-user')

          expect(result).to eq(false)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]['$feature_flag']).to eq('missing-flag')
          expect(captured_message[:properties]['$feature_flag_error']).to eq(FeatureFlagError::FLAG_MISSING)
        end
      end

      context 'when server returns errorsWhileComputingFlags' do
        it 'adds errors_while_computing_flags error to $feature_flag_called event' do
          flags_response = {
            'featureFlags' => { 'test-flag' => true },
            'featureFlagPayloads' => {},
            'errorsWhileComputingFlags' => true
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          result = client.get_feature_flag('test-flag', 'test-user')

          expect(result).to eq(true)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]['$feature_flag_error']).to eq(FeatureFlagError::ERRORS_WHILE_COMPUTING)
        end
      end

      context 'when quota limited' do
        it 'adds quota_limited and flag_missing errors to $feature_flag_called event' do
          # When quota limited, the response includes quotaLimited field and empty flags
          flags_response = {
            'featureFlags' => {},
            'featureFlagPayloads' => {},
            'quotaLimited' => ['feature_flags']
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          result = client.get_feature_flag('test-flag', 'test-user')

          # Flag is nil because quota limiting returns empty flags
          expect(result).to eq(false)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          # Both quota_limited and flag_missing are reported since the flag is not in the empty response
          expected_error = "#{FeatureFlagError::QUOTA_LIMITED},#{FeatureFlagError::FLAG_MISSING}"
          expect(captured_message[:properties]['$feature_flag_error']).to eq(expected_error)
        end
      end

      context 'when both errorsWhileComputingFlags and flag_missing occur' do
        it 'joins multiple errors with commas' do
          flags_response = {
            'featureFlags' => { 'other-flag' => true },
            'featureFlagPayloads' => {},
            'errorsWhileComputingFlags' => true
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          result = client.get_feature_flag('missing-flag', 'test-user')

          expect(result).to eq(false)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expected_error = "#{FeatureFlagError::ERRORS_WHILE_COMPUTING},#{FeatureFlagError::FLAG_MISSING}"
          expect(captured_message[:properties]['$feature_flag_error']).to eq(expected_error)
        end
      end

      context 'when API returns error status code' do
        it 'adds api_error_500 for server error' do
          stub_request(:post, flags_endpoint)
            .to_return(status: 500, body: { 'featureFlags' => {} }.to_json)

          result = client.get_feature_flag('test-flag', 'test-user')

          expect(result).to eq(false)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]['$feature_flag_error']).to eq('api_error_500,flag_missing')
        end

        it 'adds api_error_503 for service unavailable' do
          stub_request(:post, flags_endpoint)
            .to_return(status: 503, body: { 'featureFlags' => { 'test-flag' => true } }.to_json)

          result = client.get_feature_flag('test-flag', 'test-user')

          expect(result).to eq(true)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]['$feature_flag_error']).to eq('api_error_503')
        end

        it 'adds api_error_400 for bad request' do
          stub_request(:post, flags_endpoint)
            .to_return(status: 400, body: { 'featureFlags' => {} }.to_json)

          client.get_feature_flag('test-flag', 'test-user')

          captured_message = client.dequeue_last_message
          expect(captured_message[:properties]['$feature_flag_error']).to eq('api_error_400,flag_missing')
        end
      end

      context 'when request fails completely' do
        it 'adds timeout error to $feature_flag_called event on timeout' do
          stub_request(:post, flags_endpoint)
            .to_timeout

          result = client.get_feature_flag('test-flag', 'test-user')

          expect(result).to eq(nil)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]['$feature_flag_error']).to eq(FeatureFlagError::TIMEOUT)
        end

        it 'adds connection_error to $feature_flag_called event on connection error' do
          stub_request(:post, flags_endpoint)
            .to_raise(Errno::ECONNREFUSED)

          result = client.get_feature_flag('test-flag', 'test-user')

          expect(result).to eq(nil)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]['$feature_flag_error']).to eq(FeatureFlagError::CONNECTION_ERROR)
        end

        it 'adds unknown_error to $feature_flag_called event on unexpected error' do
          stub_request(:post, flags_endpoint)
            .to_raise(StandardError.new('Unexpected error'))

          result = client.get_feature_flag('test-flag', 'test-user')

          expect(result).to eq(nil)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]['$feature_flag_error']).to eq(FeatureFlagError::UNKNOWN_ERROR)
        end
      end

      context 'when request succeeds with no errors' do
        it 'does not add $feature_flag_error property' do
          flags_response = {
            'featureFlags' => { 'test-flag' => true },
            'featureFlagPayloads' => {}
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          result = client.get_feature_flag('test-flag', 'test-user')

          expect(result).to eq(true)

          captured_message = client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]).not_to have_key('$feature_flag_error')
        end
      end

      context 'when local evaluation succeeds' do
        it 'does not add $feature_flag_error property' do
          api_feature_flag_res = {
            'flags' => [
              {
                'id' => 1,
                'name' => 'Beta Feature',
                'key' => 'beta-feature',
                'active' => true,
                'is_simple_flag' => true,
                'rollout_percentage' => 100,
                'filters' => {
                  'groups' => [
                    {
                      'properties' => [],
                      'rollout_percentage' => 100
                    }
                  ]
                }
              }
            ]
          }

          stub_request(:get, feature_flag_endpoint)
            .to_return(status: 200, body: api_feature_flag_res.to_json)

          new_client = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

          new_client.get_feature_flag('beta-feature', 'test-user')

          captured_message = new_client.dequeue_last_message
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]['locally_evaluated']).to eq(true)
          expect(captured_message[:properties]).not_to have_key('$feature_flag_error')
        end
      end

      context 'when send_feature_flag_events is false' do
        it 'does not capture events even on error' do
          stub_request(:post, flags_endpoint)
            .to_raise(StandardError.new('Network error'))

          result = client.get_feature_flag('test-flag', 'test-user', send_feature_flag_events: false)

          expect(result).to eq(nil)
          expect(client.queued_messages).to eq(0)
        end
      end
    end

    describe 'FeatureFlagError constants' do
      it 'has all required error constants' do
        expect(FeatureFlagError::ERRORS_WHILE_COMPUTING).to eq('errors_while_computing_flags')
        expect(FeatureFlagError::FLAG_MISSING).to eq('flag_missing')
        expect(FeatureFlagError::QUOTA_LIMITED).to eq('quota_limited')
        expect(FeatureFlagError::TIMEOUT).to eq('timeout')
        expect(FeatureFlagError::CONNECTION_ERROR).to eq('connection_error')
        expect(FeatureFlagError::UNKNOWN_ERROR).to eq('unknown_error')
      end

      it 'generates api_error strings with status codes' do
        expect(FeatureFlagError.api_error(500)).to eq('api_error_500')
        expect(FeatureFlagError.api_error(404)).to eq('api_error_404')
        expect(FeatureFlagError.api_error(503)).to eq('api_error_503')
      end
    end
  end
end
