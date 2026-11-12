# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe 'failed flag records (spec 211)' do
    let(:flags_endpoint) { 'https://us.i.posthog.com/flags/?v=2' }
    let(:definitions_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:client) { Client.new(api_key: API_KEY, test_mode: true) }

    def failed_record(key, variant = nil)
      {
        key: key, enabled: false, variant: variant, failed: true,
        reason: { code: 'dependency_error', description: 'Evaluation failed' },
        metadata: { id: 1, version: 2, payload: '{"copy":"remote"}' }
      }
    end

    def local_flag(key, value)
      {
        key: key, active: value != false,
        filters: {
          groups: [{ properties: [], rollout_percentage: 100, variant: value.is_a?(String) ? value : nil }],
          multivariate: value.is_a?(String) ? { variants: [{ key: 'blue', rollout_percentage: 100 }] } : nil,
          payloads: { value.to_s => '{"copy":"local"}' }
        }
      }
    end

    it 'does not label a retained successful fallback value as failed' do
      poller = client.instance_variable_get(:@feature_flags_poller)
      allow(poller).to receive(:get_all_flags_and_payloads).and_return(
        featureFlags: { checkout: 'blue' }, featureFlagPayloads: { checkout: '{"copy":"local"}' },
        flagDetails: { checkout: FeatureFlag.new(failed_record('checkout')) }, errorsWhileComputingFlags: true
      )
      result = client.get_feature_flag_result('checkout', 'user')
      expect(result.value).to eq('blue')
      expect(result.payload).to eq('copy' => 'local')
      error = client.dequeue_last_message[:properties]['$feature_flag_error']
      expect(error).to eq('errors_while_computing_flags')
    end

    it 'delivers failed diagnostics through the public getter and flush transport path' do
      stub_request(:post, flags_endpoint).to_return(
        status: 200, body: { flags: { checkout: failed_record('checkout', 'placeholder') },
                             errorsWhileComputingFlags: true }.to_json
      )
      delivered = []
      ingestion = stub_request(:post, 'https://us.i.posthog.com/batch/').to_return do |request|
        delivered.concat(JSON.parse(request.body).fetch('batch'))
        { status: 200, body: '{}' }
      end
      wire_client = Client.new(api_key: API_KEY, sync_mode: true, compress_request: false)
      expect(wire_client.get_feature_flag_result('checkout', 'user')).to be_nil
      expect(wire_client.flush).to be(true)
      expect(ingestion).to have_been_requested.once
      expect(delivered.size).to eq(1)
      props = delivered.first.fetch('properties')
      expect(props['$feature_flag_response']).to be_nil
      expect(props['$feature_flag_error'].split(',')).to contain_exactly(
        'evaluation_failed', 'errors_while_computing_flags'
      )
    ensure
      wire_client&.shutdown
    end

    [nil, false, true].each do |error_bit|
      [nil, 'placeholder'].each do |variant|
        context "with global errors #{error_bit.inspect} and failed variant #{variant.inspect}" do
          let(:response) do
            result = {
              flags: {
                checkout: failed_record('checkout', variant),
                off: { key: 'off', enabled: false, failed: false }
              },
              featureFlags: { checkout: 'mirror' }, featureFlagPayloads: { checkout: '"mirror"' }
            }
            result[:errorsWhileComputingFlags] = error_bit unless error_bit.nil?
            result
          end

          before do
            stub_request(:post, flags_endpoint).to_return(status: 200, body: response.to_json)
          end

          it 'returns no rich/scalar result and reports failure with the missing response, dedupe, and suppression' do
            expect(client.get_feature_flag_result('checkout', 'user', send_feature_flag_events: false)).to be_nil
            expect(client.queued_messages).to eq(0)
            expect(client.get_feature_flag_result('checkout', 'user')).to be_nil
            expect(client.get_feature_flag('checkout', 'user')).to be_nil
            expect(client.is_feature_enabled('checkout', 'user')).to be_nil
            expect(client.queued_messages).to eq(1)
            event = client.dequeue_last_message
            expect(event[:properties]['$feature_flag_response']).to be_nil
            errors = event[:properties]['$feature_flag_error'].split(',')
            expect(errors).to include('evaluation_failed')
            expect(errors).not_to include('flag_missing')
            expect(errors.include?('errors_while_computing_flags')).to eq(error_bit == true)
            expect(client.get_feature_flag_result('off', 'user').enabled?).to be(false)
            healthy_error = client.dequeue_last_message[:properties]['$feature_flag_error'].to_s
            expect(healthy_error).not_to include('evaluation_failed')
            combined = client.get_all_flags_and_payloads('user')
            expect(combined[:featureFlags]).to eq('off' => false)
            expect(combined[:featureFlagPayloads]).not_to have_key('checkout')
          end

          it 'honors snapshot defaults, omits failed enrichment, and retains diagnostics' do
            snapshot = client.evaluate_flags('user')
            expect(snapshot.enabled?('checkout', default_value: true)).to be(true)
            expect(snapshot.get_flag('checkout')).to be_nil
            expect(snapshot.get_flag_payload('checkout')).to be_nil
            event = client.dequeue_last_message
            expect(event[:properties]['$feature_flag_response']).to be_nil
            errors = event[:properties]['$feature_flag_error'].split(',')
            expect(errors).to include('evaluation_failed')
            expect(errors).not_to include('flag_missing')
            expect(errors.include?('errors_while_computing_flags')).to eq(error_bit == true)
            expect(snapshot.keys).to eq(['off'])
            expect(snapshot.enabled?('off', default_value: true)).to be(false)
            client.capture(distinct_id: 'user', event: 'enriched', flags: snapshot)
            expect(client.dequeue_last_message[:properties]).to include('$feature/off' => false)
            expect(snapshot._get_event_properties).not_to have_key('$feature/checkout')
          end

          it 'reports evaluation_failed after inconclusive local evaluation' do
            definition = local_flag('checkout', true).merge(ensure_experience_continuity: true)
            stub_request(:get, definitions_endpoint).to_return(status: 200, body: { flags: [definition] }.to_json)
            local_client = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
            expect(local_client.get_feature_flag_result('checkout', 'user')).to be_nil
            props = local_client.dequeue_last_message[:properties]
            expect(props['$feature_flag_error']).to include('evaluation_failed')
            expect(props['$feature_flag_error']).not_to include('flag_missing')
            expect(props['$feature_flag_response']).to be_nil
          ensure
            local_client&.shutdown
          end
        end
      end

      it "preserves local true/false/variant pairs and capture enrichment with global errors #{error_bit.inspect}" do
        values = { 'on' => true, 'off' => false, 'variant' => 'blue', 'success' => true }
        definitions = values.map { |key, value| local_flag(key, value) }
        definitions << local_flag('checkout', true).merge(ensure_experience_continuity: true)
        stub_request(:get, definitions_endpoint).to_return(status: 200, body: { flags: definitions }.to_json)
        remote = { flags: (values.keys + ['checkout']).to_h { |key| [key, failed_record(key, 'placeholder')] } }
        remote[:flags]['success'] = {
          key: 'success', enabled: true, variant: 'remote', metadata: { payload: '{"copy":"success"}' }
        }
        remote[:errorsWhileComputingFlags] = error_bit unless error_bit.nil?
        stub_request(:post, flags_endpoint).to_return(status: 200, body: remote.to_json)
        local_client = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
        result = local_client.get_all_flags_and_payloads('user')
        expect(result[:featureFlags]).to eq(values.merge('success' => 'remote'))
        expected_payloads = values.to_h do |key, _|
          [key, key == 'success' ? '{"copy":"success"}' : '{"copy":"local"}']
        end
        expect(result[:featureFlagPayloads]).to eq(expected_payloads)
        local_client.capture(distinct_id: 'user', event: 'enriched', send_feature_flags: true)
        props = local_client.dequeue_last_message[:properties]
        expect(props).to include('$feature/on' => true, '$feature/off' => false, '$feature/variant' => 'blue')
        expect(props).not_to have_key('$feature/checkout')
        expect(local_client.get_feature_flag_result('on', 'user').enabled?).to be(true)
        local_error = local_client.dequeue_last_message[:properties]['$feature_flag_error'].to_s
        expect(local_error).not_to include('evaluation_failed')
      ensure
        local_client&.shutdown
      end
    end
  end
end
