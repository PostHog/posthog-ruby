require 'spec_helper'

FLAGS_ENDPOINT = 'https://app.posthog.com/flags/?v=2'.freeze
LOCAL_EVAL_ENDPOINT = 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret'.freeze

class PostHog
  describe FeatureFlagEvaluations do
    let(:flags_response) do
      {
        flags: {
          'variant-flag' => {
            key: 'variant-flag', enabled: true, variant: 'variant-value',
            reason: { code: 'condition_match', condition_index: 2, description: 'Matched condition set 3' },
            metadata: { id: 2, version: 23, payload: '{"key": "value"}', description: 'description' }
          },
          'boolean-flag' => {
            key: 'boolean-flag', enabled: true, variant: nil,
            reason: { code: 'condition_match', condition_index: 1, description: 'Matched condition set 1' },
            metadata: { id: 1, version: 12 }
          },
          'disabled-flag' => {
            key: 'disabled-flag', enabled: false, variant: nil,
            reason: { code: 'no_condition_match', condition_index: nil, description: 'Did not match any condition' },
            metadata: { id: 3, version: 2 }
          }
        },
        errorsWhileComputingFlags: false,
        requestId: 'request-id-1',
        evaluatedAt: 1_640_995_200_000
      }
    end

    def stub_flags(response = nil)
      response ||= flags_response
      stub_request(:post, FLAGS_ENDPOINT).to_return(status: 200, body: response.to_json)
    end

    def drain_messages(client)
      msgs = []
      msgs << client.dequeue_last_message until client.queued_messages.zero?
      msgs
    end

    let(:client) { Client.new(api_key: API_KEY, test_mode: true) }

    describe 'remote evaluation' do
      it 'returns a FeatureFlagEvaluations instance and makes one /flags request' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')
        expect(snapshot).to be_a(FeatureFlagEvaluations)
        expect(snapshot.keys).to match_array(%w[variant-flag boolean-flag disabled-flag])
        expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).once
      end

      it 'does not fire $feature_flag_called events for unaccessed flags' do
        stub_flags
        client.evaluate_flags('user-1')
        msgs = drain_messages(client)
        expect(msgs.any? { |m| m[:event] == '$feature_flag_called' }).to eq(false)
      end

      it 'is_enabled fires the event with full metadata on first access and dedupes on second' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')

        expect(snapshot.is_enabled('boolean-flag')).to eq(true)
        msgs = drain_messages(client)
        event = msgs.find { |m| m[:event] == '$feature_flag_called' }
        expect(event).not_to be_nil
        expect(event[:properties]['$feature_flag']).to eq('boolean-flag')
        expect(event[:properties]['$feature_flag_response']).to eq(true)
        expect(event[:properties]['$feature_flag_id']).to eq(1)
        expect(event[:properties]['$feature_flag_version']).to eq(12)
        expect(event[:properties]['$feature_flag_reason']).to eq('Matched condition set 1')
        expect(event[:properties]['$feature_flag_request_id']).to eq('request-id-1')
        expect(event[:properties]['locally_evaluated']).to eq(false)

        snapshot.is_enabled('boolean-flag')
        msgs = drain_messages(client)
        expect(msgs.any? { |m| m[:event] == '$feature_flag_called' }).to eq(false)
      end

      it 'get_flag returns variant strings, booleans, and nil for unknown flags' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')

        expect(snapshot.get_flag('variant-flag')).to eq('variant-value')
        expect(snapshot.get_flag('boolean-flag')).to eq(true)
        expect(snapshot.get_flag('disabled-flag')).to eq(false)
        expect(snapshot.get_flag('not-a-flag')).to be_nil

        msgs = drain_messages(client).select { |m| m[:event] == '$feature_flag_called' }
        unknown = msgs.find { |m| m[:properties]['$feature_flag'] == 'not-a-flag' }
        expect(unknown[:properties]['$feature_flag_error']).to eq('flag_missing')
      end

      it 'is_enabled returns false for unknown flags' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')
        expect(snapshot.is_enabled('not-a-flag')).to eq(false)
      end

      it 'get_flag_payload does not fire an event' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')
        snapshot.get_flag_payload('variant-flag')
        msgs = drain_messages(client)
        expect(msgs.any? { |m| m[:event] == '$feature_flag_called' }).to eq(false)
      end

      it 'forwards flag_keys to the /flags request body as flag_keys_to_evaluate' do
        stub_flags
        client.evaluate_flags('user-1', flag_keys: %w[boolean-flag])
        expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).with(
          body: hash_including(flag_keys_to_evaluate: %w[boolean-flag])
        )
      end

      it 'returns a usable empty snapshot for empty distinct_id and does not call /flags' do
        stub_flags
        snapshot = client.evaluate_flags('')
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
        expect(snapshot.keys).to eq([])
        expect(snapshot.is_enabled('anything')).to eq(false)
        expect(snapshot.get_flag('anything')).to be_nil
        msgs = drain_messages(client)
        expect(msgs.any? { |m| m[:event] == '$feature_flag_called' }).to eq(false)
      end
    end

    describe 'filtering helpers' do
      it 'only_accessed returns a snapshot with just the accessed flags' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')
        snapshot.is_enabled('boolean-flag')
        filtered = snapshot.only_accessed
        expect(filtered.keys).to eq(%w[boolean-flag])
      end

      it 'only_accessed warns and falls back to all flags when nothing was accessed' do
        stub_flags
        warned = []
        c = Client.new(api_key: API_KEY, test_mode: true)
        allow(c.send(:logger)).to receive(:warn) { |m| warned << m }
        stub_flags
        snapshot = c.evaluate_flags('user-1')
        filtered = snapshot.only_accessed
        expect(filtered.keys).to match_array(%w[variant-flag boolean-flag disabled-flag])
        expect(warned.any? { |m| m.include?('only_accessed') }).to eq(true)
      end

      it 'silences filter warnings when feature_flags_log_warnings: false' do
        warned = []
        c = Client.new(api_key: API_KEY, test_mode: true, feature_flags_log_warnings: false)
        allow(c.send(:logger)).to receive(:warn) { |m| warned << m }
        stub_flags
        snapshot = c.evaluate_flags('user-1')
        snapshot.only_accessed
        expect(warned).to eq([])
      end

      it 'only(keys) drops unknown keys with a warning' do
        warned = []
        c = Client.new(api_key: API_KEY, test_mode: true)
        allow(c.send(:logger)).to receive(:warn) { |m| warned << m }
        stub_flags
        snapshot = c.evaluate_flags('user-1')
        filtered = snapshot.only(%w[boolean-flag does-not-exist])
        expect(filtered.keys).to eq(%w[boolean-flag])
        expect(warned.any? { |m| m.include?('does-not-exist') }).to eq(true)
      end

      it 'filtered snapshots do not back-propagate access to the parent' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')
        snapshot.is_enabled('boolean-flag')
        filtered = snapshot.only_accessed
        filtered.is_enabled('variant-flag')
        # parent still only has boolean-flag accessed; only_accessed reflects that
        reaccessed = snapshot.only_accessed
        expect(reaccessed.keys).to eq(%w[boolean-flag])
      end
    end

    describe 'capture(flags:)' do
      it 'attaches $feature/* and $active_feature_flags from the snapshot without an extra /flags call' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')
        WebMock.reset_executed_requests!

        client.capture(distinct_id: 'user-1', event: 'test-event', flags: snapshot)
        msgs = drain_messages(client)
        event = msgs.find { |m| m[:event] == 'test-event' }
        expect(event).not_to be_nil
        props = event[:properties]
        expect(props['$feature/variant-flag']).to eq('variant-value')
        expect(props['$feature/boolean-flag']).to eq(true)
        expect(props['$feature/disabled-flag']).to eq(false)
        expect(props['$active_feature_flags']).to eq(%w[boolean-flag variant-flag])
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
      end

      it 'capture(flags: snapshot.only_accessed) attaches only accessed flags' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')
        snapshot.is_enabled('boolean-flag')

        client.capture(distinct_id: 'user-1', event: 'test-event', flags: snapshot.only_accessed)
        msgs = drain_messages(client)
        event = msgs.find { |m| m[:event] == 'test-event' }
        expect(event[:properties]['$feature/boolean-flag']).to eq(true)
        expect(event[:properties].keys).not_to include('$feature/variant-flag')
        expect(event[:properties]['$active_feature_flags']).to eq(%w[boolean-flag])
      end

      it 'flags: takes precedence over send_feature_flags' do
        stub_flags
        snapshot = client.evaluate_flags('user-1')
        WebMock.reset_executed_requests!

        client.capture(
          distinct_id: 'user-1', event: 'test-event',
          flags: snapshot, send_feature_flags: true
        )
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
      end
    end

    describe 'local evaluation' do
      let(:local_definitions) do
        {
          flags: [
            {
              id: 99, name: 'Local flag', key: 'local-flag', active: true,
              filters: { groups: [{ properties: [], rollout_percentage: 100 }] }
            }
          ]
        }
      end

      it 'tags locally-evaluated flags and skips remote when only_evaluate_locally' do
        stub_request(:get, LOCAL_EVAL_ENDPOINT).to_return(status: 200, body: local_definitions.to_json)
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
        snapshot = c.evaluate_flags('user-1', only_evaluate_locally: true)

        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
        expect(snapshot.is_enabled('local-flag')).to eq(true)

        msgs = drain_messages(c).select { |m| m[:event] == '$feature_flag_called' }
        event = msgs.find { |m| m[:properties]['$feature_flag'] == 'local-flag' }
        expect(event).not_to be_nil
        expect(event[:properties]['locally_evaluated']).to eq(true)
        expect(event[:properties]['$feature_flag_reason']).to eq('Evaluated locally')
        expect(event[:properties]['$feature_flag_id']).to eq(99)
        expect(event[:properties]['$feature_flag_definitions_loaded_at']).to be_a(Integer)
      end
    end
  end
end
