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

    describe 'failed flag filtering' do
      context 'when a flag has failed=true' do
        it 'excludes the failed flag even when enabled is true, and preserves non-failed flags' do
          flags_response = {
            'flags' => {
              'my-flag' => {
                'key' => 'my-flag',
                'enabled' => true,
                'variant' => nil,
                'reason' => { 'code' => 'database_error', 'description' => 'Database connection error' },
                'metadata' => { 'id' => 1, 'version' => 1, 'payload' => nil },
                'failed' => true
              },
              'good-flag' => {
                'key' => 'good-flag',
                'enabled' => true,
                'variant' => nil,
                'reason' => { 'code' => 'condition_match', 'description' => 'Matched', 'condition_index' => 0 },
                'metadata' => { 'id' => 2, 'version' => 1, 'payload' => nil },
                'failed' => false
              }
            },
            'errorsWhileComputingFlags' => true,
            'requestId' => 'test-request-id'
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          # The failed flag has enabled=true, but should be filtered out and treated as missing.
          # Without filtering, this would return true.
          result = client.get_feature_flag('my-flag', 'test-user')
          expect(result).to eq(false)
          captured_message = client.dequeue_last_message
          expect(captured_message[:properties]['$feature_flag_error']).to include(FeatureFlagError::FLAG_MISSING)

          # The non-failed flag should return its value normally
          good_result = client.get_feature_flag('good-flag', 'test-user')
          expect(good_result).to eq(true)
        end

        it 'excludes a failed flag with a variant from the response' do
          flags_response = {
            'flags' => {
              'variant-flag' => {
                'key' => 'variant-flag',
                'enabled' => true,
                'variant' => 'test-variant',
                'reason' => { 'code' => 'timeout', 'description' => 'Database statement timed out' },
                'metadata' => { 'id' => 3, 'version' => 1, 'payload' => nil },
                'failed' => true
              }
            },
            'errorsWhileComputingFlags' => true,
            'requestId' => 'test-request-id'
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          # Without filtering, this would return 'test-variant'.
          result = client.get_feature_flag('variant-flag', 'test-user')
          expect(result).to eq(false)
          captured_message = client.dequeue_last_message
          expect(captured_message[:properties]['$feature_flag_error']).to include(FeatureFlagError::FLAG_MISSING)
        end

        it 'excludes failed flags from get_all_flags results' do
          flags_response = {
            'flags' => {
              'failed-flag' => {
                'key' => 'failed-flag',
                'enabled' => true,
                'variant' => nil,
                'reason' => { 'code' => 'database_error', 'description' => 'Database connection error' },
                'metadata' => { 'id' => 1, 'version' => 1, 'payload' => nil },
                'failed' => true
              },
              'ok-flag' => {
                'key' => 'ok-flag',
                'enabled' => true,
                'variant' => nil,
                'reason' => { 'code' => 'condition_match', 'description' => 'Matched', 'condition_index' => 0 },
                'metadata' => { 'id' => 2, 'version' => 1, 'payload' => nil },
                'failed' => false
              }
            },
            'errorsWhileComputingFlags' => true,
            'requestId' => 'test-request-id'
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          all_flags = client.get_all_flags('test-user')

          # failed-flag should be excluded despite having enabled=true
          expect(all_flags).not_to have_key('failed-flag')
          # ok-flag should be present with its value
          expect(all_flags['ok-flag']).to eq(true)
        end
      end

      context 'when a locally-evaluated flag fails on the server during fallback' do
        it 'preserves the locally-evaluated true value instead of overwriting with failed false' do
          # Setup: two flags in local definitions
          # - beta-feature: simple flag, 100% rollout → evaluates locally to true
          # - server-only-flag: has experience continuity → requires server evaluation, triggers fallback
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
              },
              {
                'id' => 2,
                'name' => 'Server Only Flag',
                'key' => 'server-only-flag',
                'active' => true,
                'is_simple_flag' => false,
                'ensure_experience_continuity' => true,
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

          # Server response: beta-feature failed (transient DB error), server-only-flag succeeded
          flags_response = {
            'flags' => {
              'beta-feature' => {
                'key' => 'beta-feature',
                'enabled' => false,
                'variant' => nil,
                'reason' => { 'code' => 'database_error', 'description' => 'Database connection error' },
                'metadata' => { 'id' => 1, 'version' => 1, 'payload' => nil },
                'failed' => true
              },
              'server-only-flag' => {
                'key' => 'server-only-flag',
                'enabled' => true,
                'variant' => nil,
                'reason' => { 'code' => 'condition_match', 'description' => 'Matched', 'condition_index' => 0 },
                'metadata' => { 'id' => 2, 'version' => 1, 'payload' => nil },
                'failed' => false
              }
            },
            'errorsWhileComputingFlags' => true,
            'requestId' => 'test-request-id'
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          new_client = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

          # get_all_flags triggers local eval for both flags:
          # - beta-feature evaluates locally to true
          # - server-only-flag raises RequiresServerEvaluation → triggers server fallback
          # Server returns beta-feature as failed: true, enabled: false
          # The locally-evaluated true must be preserved, NOT overwritten by the failed false.
          all_flags = new_client.get_all_flags('test-user')

          expect(all_flags['beta-feature']).to eq(true)
          expect(all_flags['server-only-flag']).to eq(true)
        end
      end

      context 'when the failed field is absent (backward compatibility)' do
        it 'includes flags without a failed field normally' do
          flags_response = {
            'flags' => {
              'legacy-flag' => {
                'key' => 'legacy-flag',
                'enabled' => true,
                'variant' => nil,
                'reason' => { 'code' => 'condition_match', 'description' => 'Matched', 'condition_index' => 0 },
                'metadata' => { 'id' => 1, 'version' => 1, 'payload' => nil }
              }
            },
            'requestId' => 'test-request-id'
          }

          stub_request(:post, flags_endpoint)
            .to_return(status: 200, body: flags_response.to_json)

          result = client.get_feature_flag('legacy-flag', 'test-user')
          expect(result).to eq(true)
        end
      end
    end
  end
end
