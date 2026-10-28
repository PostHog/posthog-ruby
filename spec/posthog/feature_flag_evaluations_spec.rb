# frozen_string_literal: true

require 'spec_helper'

FLAGS_ENDPOINT = 'https://us.i.posthog.com/flags/?v=2'
LOCAL_EVAL_ENDPOINT = 'https://app.posthog.com/flags/definitions?token=testsecret&send_cohorts=true'

module PostHog
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

    def stub_flags(response)
      stub_request(:post, FLAGS_ENDPOINT).to_return(status: 200, body: response.to_json)
    end

    def drain_messages(client)
      msgs = []
      msgs << client.dequeue_last_message until client.queued_messages.zero?
      msgs
    end

    def flag_called_properties(client, key)
      client.evaluate_flags('user-1').enabled?(key)
      event = drain_messages(client).find do |m|
        m[:event] == '$feature_flag_called' && m[:properties]['$feature_flag'] == key
      end
      event[:properties]
    end

    def capture_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
      $stderr.string
    ensure
      $stderr = original
    end

    let(:client) { Client.new(api_key: API_KEY, test_mode: true) }

    describe 'remote evaluation' do
      it 'returns a FeatureFlagEvaluations instance and makes one /flags request' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        expect(snapshot).to be_a(FeatureFlagEvaluations)
        expect(snapshot.keys).to match_array(%w[variant-flag boolean-flag disabled-flag])
        expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).once
      end

      it 'does not fire $feature_flag_called events for unaccessed flags' do
        stub_flags(flags_response)
        client.evaluate_flags('user-1')
        msgs = drain_messages(client)
        expect(msgs.any? { |m| m[:event] == '$feature_flag_called' }).to be(false)
      end

      it 'enabled? fires the event with full metadata on first access and dedupes on second' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')

        expect(snapshot.enabled?('boolean-flag')).to be(true)
        msgs = drain_messages(client)
        event = msgs.find { |m| m[:event] == '$feature_flag_called' }
        expect(event).not_to be_nil
        expect(event[:properties]['$feature_flag']).to eq('boolean-flag')
        expect(event[:properties]['$feature_flag_response']).to be(true)
        expect(event[:properties]['$feature_flag_id']).to eq(1)
        expect(event[:properties]['$feature_flag_version']).to eq(12)
        expect(event[:properties]['$feature_flag_reason']).to eq('Matched condition set 1')
        expect(event[:properties]['$feature_flag_request_id']).to eq('request-id-1')
        expect(event[:properties]['locally_evaluated']).to be(false)

        snapshot.enabled?('boolean-flag')
        msgs = drain_messages(client)
        expect(msgs.any? { |m| m[:event] == '$feature_flag_called' }).to be(false)
      end

      it 'get_flag returns variant strings, booleans, and nil for unknown flags' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')

        expect(snapshot.get_flag('variant-flag')).to eq('variant-value')
        expect(snapshot.get_flag('boolean-flag')).to be(true)
        expect(snapshot.get_flag('disabled-flag')).to be(false)
        expect(snapshot.get_flag('not-a-flag')).to be_nil

        msgs = drain_messages(client).select { |m| m[:event] == '$feature_flag_called' }
        unknown = msgs.find { |m| m[:properties]['$feature_flag'] == 'not-a-flag' }
        expect(unknown[:properties]['$feature_flag_error']).to eq('flag_missing')
      end

      it 'accepts symbol flag keys when reading a snapshot' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')

        expect(snapshot.enabled?(:'boolean-flag')).to be(true)
        expect(snapshot.get_flag(:'variant-flag')).to eq('variant-value')
        expect(snapshot.get_flag_payload(:'variant-flag')).to eq('key' => 'value')
        expect(snapshot.only(:'boolean-flag').keys).to eq(['boolean-flag'])
      end

      it 'enabled? returns false for unknown flags' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        expect(snapshot.enabled?('not-a-flag')).to be(false)
      end

      it 'enabled? resolves a missing flag to the caller-supplied default' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        expect(snapshot.enabled?('not-a-flag', default_value: true)).to be(true)
        expect(snapshot.enabled?('not-a-flag', default_value: false)).to be(false)
      end

      it 'enabled? prefers an existing flag value over the caller-supplied default' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        expect(snapshot.enabled?('disabled-flag', default_value: true)).to be(false)
        expect(snapshot.enabled?('variant-flag', default_value: false)).to be(true)
        expect(snapshot.enabled?('boolean-flag', default_value: false)).to be(true)
      end

      it 'enabled? uses the caller default on an empty snapshot' do
        snapshot = client.evaluate_flags('')
        expect(snapshot.enabled?('anything', default_value: true)).to be(true)
        expect(snapshot.enabled?('anything')).to be(false)
      end

      it 'enabled? uses the caller default when the /flags request fails' do
        stub_request(:post, FLAGS_ENDPOINT).to_return(status: 500, body: 'error')
        snapshot = client.evaluate_flags('user-1')
        expect(snapshot.enabled?('boolean-flag', default_value: true)).to be(true)
        expect(snapshot.enabled?('boolean-flag')).to be(false)
      end

      it 'enabled? keeps a flag marked failed by /flags as false, ignoring the caller default' do
        stub_flags(
          flags: { 'failed-flag' => { key: 'failed-flag', enabled: false, variant: nil, failed: true } },
          errorsWhileComputingFlags: true
        )
        snapshot = client.evaluate_flags('user-1')
        expect(snapshot.enabled?('failed-flag', default_value: true)).to be(false)
      end

      it 'enabled? still reports the evaluated response, not the default, on $feature_flag_called' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        snapshot.enabled?('not-a-flag', default_value: true)

        msgs = drain_messages(client).select do |m|
          m[:event] == '$feature_flag_called' && m[:properties]['$feature_flag'] == 'not-a-flag'
        end
        expect(msgs.length).to eq(1)
        expect(msgs.first[:properties]['$feature_flag_response']).to be_nil
        expect(msgs.first[:properties]['$feature_flag_error']).to eq('flag_missing')
      end

      it 'enabled? and get_flag on a variant flag dedupe to a single event with the variant response' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')

        expect(snapshot.enabled?('variant-flag')).to be(true)
        expect(snapshot.get_flag('variant-flag')).to eq('variant-value')

        msgs = drain_messages(client).select do |m|
          m[:event] == '$feature_flag_called' && m[:properties]['$feature_flag'] == 'variant-flag'
        end
        expect(msgs.length).to eq(1)
        expect(msgs.first[:properties]['$feature_flag_response']).to eq('variant-value')
        expect(msgs.first[:properties]['$feature/variant-flag']).to eq('variant-value')
      end

      it 'enabled? and get_flag on a missing flag dedupe to a single event' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')

        snapshot.enabled?('not-a-flag')
        snapshot.get_flag('not-a-flag')

        msgs = drain_messages(client).select do |m|
          m[:event] == '$feature_flag_called' && m[:properties]['$feature_flag'] == 'not-a-flag'
        end
        expect(msgs.length).to eq(1)
        expect(msgs.first[:properties]['$feature_flag_response']).to be_nil
        expect(msgs.first[:properties]['$feature_flag_error']).to eq('flag_missing')
      end

      it 'get_flag_payload does not fire an event' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        2.times { expect(snapshot.get_flag_payload('variant-flag')).to eq('key' => 'value') }
        expect(snapshot.only_accessed.keys).to eq([])
        expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).once
        msgs = drain_messages(client)
        expect(msgs.any? { |m| m[:event] == '$feature_flag_called' }).to be(false)
      end

      it 'forwards flag_keys to the /flags request body as flag_keys_to_evaluate' do
        stub_flags(flags_response)
        client.evaluate_flags('user-1', flag_keys: %w[boolean-flag])
        expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).with(
          body: hash_including(flag_keys_to_evaluate: %w[boolean-flag])
        )
      end

      it 'accepts symbol keys in the flag_keys filter array' do
        stub_flags(flags_response)
        client.evaluate_flags('user-1', flag_keys: [:'boolean-flag'])
        expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).with(
          body: hash_including(flag_keys_to_evaluate: %w[boolean-flag])
        )
      end

      it 'returns an empty snapshot for empty flag_keys without poller or remote work' do
        stub_flags(flags_response)
        poller = client.instance_variable_get(:@feature_flags_poller)
        expect(poller).not_to receive(:load_feature_flags)
        expect(poller).not_to receive(:feature_flags_by_key)
        expect(poller).not_to receive(:_compute_flag_locally)
        expect(poller).not_to receive(:get_flags)

        snapshot = client.evaluate_flags('user-1', flag_keys: [])

        expect(snapshot).to be_a(FeatureFlagEvaluations)
        expect(snapshot.keys).to eq([])
        expect(snapshot.enabled?('missing-flag')).to be(false)
        expect(snapshot.get_flag('missing-flag')).to be_nil

        events = drain_messages(client).select { |message| message[:event] == '$feature_flag_called' }
        expect(events.length).to eq(1)
        expect(events.first[:properties]['$feature_flag_error']).to eq('flag_missing')
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
      end

      it 'treats nil flag_keys as an unscoped evaluation' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1', flag_keys: nil)
        expect(snapshot.keys).to match_array(%w[variant-flag boolean-flag disabled-flag])
        expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).once
      end

      it 'returns a usable empty snapshot for empty distinct_id and does not call /flags' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('')
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
        expect(snapshot.keys).to eq([])
        expect(snapshot.enabled?('anything')).to be(false)
        expect(snapshot.get_flag('anything')).to be_nil
        msgs = drain_messages(client)
        expect(msgs.any? { |m| m[:event] == '$feature_flag_called' }).to be(false)
      end
    end

    describe 'filtering helpers' do
      it 'only_accessed returns a snapshot with just the accessed flags' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        snapshot.enabled?('boolean-flag')
        filtered = snapshot.only_accessed
        expect(filtered.keys).to eq(%w[boolean-flag])
      end

      it 'only_accessed returns an empty snapshot when nothing has been accessed' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        filtered = snapshot.only_accessed
        expect(filtered.keys).to eq([])
      end

      it 'only(keys) drops unknown keys with a warning' do
        warned = []
        c = Client.new(api_key: API_KEY, test_mode: true)
        allow(c.send(:logger)).to receive(:warn) { |m| warned << m }
        stub_flags(flags_response)
        snapshot = c.evaluate_flags('user-1')
        filtered = snapshot.only(%w[boolean-flag does-not-exist])
        expect(filtered.keys).to eq(%w[boolean-flag])
        expect(warned.any? { |m| m.include?('does-not-exist') }).to be(true)
      end

      it 'filtered snapshots do not back-propagate access to the parent' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        snapshot.enabled?('boolean-flag')
        filtered = snapshot.only_accessed
        filtered.enabled?('variant-flag')
        reaccessed = snapshot.only_accessed
        expect(reaccessed.keys).to eq(%w[boolean-flag])
      end
    end

    describe 'capture(flags:)' do
      it 'attaches $feature/* and $active_feature_flags from the snapshot without an extra /flags call' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        WebMock.reset_executed_requests!

        client.capture(distinct_id: 'user-1', event: 'test-event', flags: snapshot)
        msgs = drain_messages(client)
        event = msgs.find { |m| m[:event] == 'test-event' }
        expect(event).not_to be_nil
        props = event[:properties]
        expect(props['$feature/variant-flag']).to eq('variant-value')
        expect(props['$feature/boolean-flag']).to be(true)
        expect(props['$feature/disabled-flag']).to be(false)
        expect(props['$active_feature_flags']).to eq(%w[boolean-flag variant-flag])
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
      end

      it 'capture(flags: snapshot.only_accessed) attaches only accessed flags' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        snapshot.enabled?('boolean-flag')

        client.capture(distinct_id: 'user-1', event: 'test-event', flags: snapshot.only_accessed)
        msgs = drain_messages(client)
        event = msgs.find { |m| m[:event] == 'test-event' }
        expect(event[:properties]['$feature/boolean-flag']).to be(true)
        expect(event[:properties].keys).not_to include('$feature/variant-flag')
        expect(event[:properties]['$active_feature_flags']).to eq(%w[boolean-flag])
      end

      it 'flags: takes precedence over send_feature_flags and warns' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        WebMock.reset_executed_requests!

        warned = []
        allow(client.send(:logger)).to receive(:warn) { |m| warned << m }
        # Suppress the DeprecationWarning on send_feature_flags so we only assert the precedence warning
        Kernel.silence_warnings do
          client.capture(
            distinct_id: 'user-1', event: 'test-event',
            flags: snapshot, send_feature_flags: true
          )
        end
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
        expect(warned.any? { |m| m.include?('Both `flags` and `send_feature_flags`') }).to be(true)
        event = drain_messages(client).find { |message| message[:event] == 'test-event' }
        expect(event[:properties]).to include(
          '$feature/variant-flag' => 'variant-value',
          '$feature/disabled-flag' => false,
          '$active_feature_flags' => %w[boolean-flag variant-flag]
        )
      end

      it 'logs and ignores flags: when given a non-snapshot value (no NoMethodError)' do
        warned = []
        allow(client.send(:logger)).to receive(:warn) { |m| warned << m }

        expect do
          client.capture(distinct_id: 'user-1', event: 'test-event', flags: 'not-a-snapshot')
        end.not_to raise_error
        msgs = drain_messages(client)
        event = msgs.find { |m| m[:event] == 'test-event' }
        expect(event).not_to be_nil
        expect(event[:properties].keys.grep(%r{^\$feature/})).to be_empty
        expect(warned.any? { |m| m.include?('expects a PostHog::FeatureFlagEvaluations snapshot') }).to be(true)
      end

      it 'capture_exception forwards flags: to the inner capture' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')

        begin
          raise 'boom'
        rescue StandardError => e
          client.capture_exception(e, 'user-1', flags: snapshot)
        end
        msgs = drain_messages(client)
        event = msgs.find { |m| m[:event] == '$exception' }
        expect(event).not_to be_nil
        expect(event[:properties]['$feature/variant-flag']).to eq('variant-value')
        expect(event[:properties]['$active_feature_flags']).to eq(%w[boolean-flag variant-flag])
      end
    end

    describe '$feature_flag_has_experiment' do
      let(:has_experiment_response) do
        {
          flags: {
            'experiment-flag' => {
              key: 'experiment-flag', enabled: true, variant: nil,
              metadata: { id: 10, version: 1, has_experiment: true }
            },
            'plain-flag' => {
              key: 'plain-flag', enabled: true, variant: nil,
              metadata: { id: 11, version: 1, has_experiment: false }
            },
            'legacy-flag' => {
              key: 'legacy-flag', enabled: true, variant: nil,
              metadata: { id: 12, version: 1 }
            }
          },
          requestId: 'request-id-2'
        }
      end

      it 'is true when the server reports has_experiment' do
        stub_flags(has_experiment_response)
        expect(flag_called_properties(client, 'experiment-flag')['$feature_flag_has_experiment']).to be(true)
      end

      it 'is false when the server reports has_experiment false' do
        stub_flags(has_experiment_response)
        expect(flag_called_properties(client, 'plain-flag')['$feature_flag_has_experiment']).to be(false)
      end

      it 'is omitted when the server does not report has_experiment' do
        stub_flags(has_experiment_response)
        expect(flag_called_properties(client, 'legacy-flag')).not_to have_key('$feature_flag_has_experiment')
      end

      it 'is omitted for flags missing from the evaluation' do
        stub_flags(has_experiment_response)
        expect(flag_called_properties(client, 'not-a-flag')).not_to have_key('$feature_flag_has_experiment')
      end
    end

    describe 'minimal $feature_flag_called events' do
      let(:gated_response) do
        {
          flags: {
            'plain-flag' => {
              key: 'plain-flag', enabled: true, variant: nil,
              reason: { code: 'condition_match', condition_index: 1, description: 'Matched condition set 1' },
              metadata: { id: 11, version: 2, payload: '{"key": "value"}', has_experiment: false }
            },
            'experiment-flag' => {
              key: 'experiment-flag', enabled: true, variant: nil,
              metadata: { id: 10, version: 1, has_experiment: true }
            },
            'legacy-flag' => {
              key: 'legacy-flag', enabled: true, variant: nil,
              metadata: { id: 12, version: 1 }
            }
          },
          requestId: 'request-id-3',
          minimalFlagCalledEvents: true
        }
      end

      it 'sends only the allowlisted properties for a gated flag without an experiment' do
        stub_flags(gated_response)
        properties = flag_called_properties(client, 'plain-flag')
        expect(properties.keys).to match_array(
          %w[$feature_flag $feature_flag_response $feature_flag_has_experiment $feature_flag_id
             $feature_flag_version $feature_flag_reason $feature_flag_request_id $groups $is_server
             locally_evaluated $lib $lib_version]
        )
        expect(properties['$feature_flag_has_experiment']).to be(false)
      end

      it 'sends the full event for a gated flag with an experiment' do
        stub_flags(gated_response)
        properties = flag_called_properties(client, 'experiment-flag')
        expect(properties['$feature_flag_has_experiment']).to be(true)
        expect(properties['$feature/experiment-flag']).to be(true)
      end

      it 'sends the full event when the flag does not report has_experiment' do
        stub_flags(gated_response)
        expect(flag_called_properties(client, 'legacy-flag')['$feature/legacy-flag']).to be(true)
      end

      it 'sends the full event when the /flags response omits the gate' do
        stub_flags(gated_response.except(:minimalFlagCalledEvents))
        expect(flag_called_properties(client, 'plain-flag')['$feature/plain-flag']).to be(true)
      end

      it 'reads the gate from the local evaluation definitions payload' do
        stub_request(:get, 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true')
          .to_return(status: 200, body: {
            'flags' => [{
              'id' => 1, 'key' => 'local-flag', 'active' => true, 'has_experiment' => false,
              'filters' => { 'groups' => [{ 'rollout_percentage' => 100 }] }
            }],
            'minimal_flag_called_events' => true
          }.to_json)
        local_client = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        snapshot = local_client.evaluate_flags('user-1', only_evaluate_locally: true)
        expect(snapshot.enabled?('local-flag')).to be(true)

        event = drain_messages(local_client).find { |m| m[:event] == '$feature_flag_called' }
        properties = event[:properties]
        expect(properties.keys).to match_array(
          %w[$feature_flag $feature_flag_response $feature_flag_has_experiment $feature_flag_id
             $feature_flag_reason $groups $is_server locally_evaluated $lib $lib_version]
        )
        expect(properties['locally_evaluated']).to be(true)
      end

      it 'does not leak a true poller gate into a mixed snapshot when the /flags response omits it' do
        stub_request(:get, %r{https://us\.i\.posthog\.com/flags/definitions})
          .to_return(status: 200, body: { 'flags' => [], 'minimal_flag_called_events' => true }.to_json)
        stub_flags(gated_response.except(:minimalFlagCalledEvents))
        mixed_client = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        properties = flag_called_properties(mixed_client, 'plain-flag')

        expect(properties['$feature/plain-flag']).to be(true)
      end
    end

    describe 'response-level errors' do
      it 'combines errorsWhileComputingFlags with flag_missing on $feature_flag_error' do
        stub_flags(flags_response.merge(errorsWhileComputingFlags: true))
        snapshot = client.evaluate_flags('user-1')

        snapshot.enabled?('boolean-flag')
        snapshot.enabled?('missing-flag')
        msgs = drain_messages(client).select { |m| m[:event] == '$feature_flag_called' }
        by_key = msgs.to_h { |m| [m[:properties]['$feature_flag'], m[:properties]] }

        expect(by_key['boolean-flag']['$feature_flag_error']).to eq('errors_while_computing_flags')
        expect(by_key['missing-flag']['$feature_flag_error']).to eq('errors_while_computing_flags,flag_missing')
      end

      it 'tags quota_limited from response' do
        stub_flags(flags_response.merge(quotaLimited: ['feature_flags']))
        snapshot = client.evaluate_flags('user-1')
        snapshot.enabled?('boolean-flag')
        msg = drain_messages(client).find { |m| m[:event] == '$feature_flag_called' }
        expect(msg[:properties]['$feature_flag_error']).to eq('quota_limited')
      end
    end

    describe 'Phase 2 deprecation warnings' do
      it 'is_feature_enabled emits a deprecation warning pointing at evaluate_flags' do
        stub_flags(flags_response)
        out = capture_stderr { client.is_feature_enabled('boolean-flag', 'user-1') }
        expect(out).to include('is_feature_enabled')
        expect(out).to include('evaluate_flags')
      end

      it 'get_feature_flag emits a deprecation warning' do
        stub_flags(flags_response)
        out = capture_stderr { client.get_feature_flag('boolean-flag', 'user-1') }
        expect(out).to include('get_feature_flag')
        expect(out).to include('evaluate_flags')
      end

      it 'get_feature_flag_result emits a deprecation warning' do
        stub_flags(flags_response)
        out = capture_stderr { client.get_feature_flag_result('boolean-flag', 'user-1') }
        expect(out).to include('get_feature_flag_result')
      end

      it 'get_feature_flag_payload emits a deprecation warning' do
        stub_flags(flags_response)
        out = capture_stderr { client.get_feature_flag_payload('boolean-flag', 'user-1') }
        expect(out).to include('get_feature_flag_payload')
      end

      it 'capture(send_feature_flags:) emits a deprecation warning' do
        stub_flags(flags_response)
        out = capture_stderr do
          client.capture(distinct_id: 'user-1', event: 'test', send_feature_flags: true)
        end
        expect(out).to include('send_feature_flags')
        expect(out).to include('evaluate_flags')
      end

      it 'is_feature_enabled emits exactly one deprecation warning per call (no cascade)' do
        stub_flags(flags_response)
        out = capture_stderr { client.is_feature_enabled('boolean-flag', 'user-1') }
        # Count occurrences of the deprecation lead phrase
        count = out.scan('is deprecated and will be removed').length
        expect(count).to eq(1)
      end

      it 'emits each deprecation warning at most once per client (suppresses repeats)' do
        stub_flags(flags_response)
        c = Client.new(api_key: API_KEY, test_mode: true)
        out = capture_stderr do
          5.times { |index| c.is_feature_enabled('boolean-flag', "user-#{index}") }
        end
        count = out.scan('`is_feature_enabled` is deprecated').length
        expect(count).to eq(1)
      end
    end

    describe 'local evaluation' do
      let(:local_definitions) do
        {
          flags: [
            {
              id: 99, name: 'Local flag', key: 'local-flag', active: true, has_experiment: true,
              filters: { groups: [{ properties: [], rollout_percentage: 100 }] }
            },
            {
              id: 100, name: 'Plain local flag', key: 'plain-local-flag', active: true,
              filters: { groups: [{ properties: [], rollout_percentage: 100 }] }
            }
          ]
        }
      end

      it 'tags locally-evaluated flags and skips remote when only_evaluate_locally' do
        stub_request(:get, %r{https://us\.i\.posthog\.com/flags/definitions})
          .to_return(status: 200, body: local_definitions.to_json)
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
        snapshot = c.evaluate_flags('user-1', only_evaluate_locally: true)

        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
        expect(snapshot.enabled?('local-flag')).to be(true)

        msgs = drain_messages(c).select { |m| m[:event] == '$feature_flag_called' }
        event = msgs.find { |m| m[:properties]['$feature_flag'] == 'local-flag' }
        expect(event).not_to be_nil
        expect(event[:properties]['locally_evaluated']).to be(true)
        expect(event[:properties]['$feature_flag_reason']).to eq('Evaluated locally')
        expect(event[:properties]['$feature_flag_id']).to eq(99)
        expect(event[:properties]['$feature_flag_definitions_loaded_at']).to be_a(Integer)
      end

      it 'sources $feature_flag_has_experiment from the local flag definition' do
        stub_request(:get, %r{https://us\.i\.posthog\.com/flags/definitions})
          .to_return(status: 200, body: local_definitions.to_json)
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
        snapshot = c.evaluate_flags('user-1', only_evaluate_locally: true)

        snapshot.enabled?('local-flag')
        snapshot.enabled?('plain-local-flag')

        msgs = drain_messages(c).select { |m| m[:event] == '$feature_flag_called' }
        by_key = msgs.to_h { |m| [m[:properties]['$feature_flag'], m[:properties]] }
        expect(by_key['local-flag']['$feature_flag_has_experiment']).to be(true)
        expect(by_key['plain-local-flag']).not_to have_key('$feature_flag_has_experiment')
      end

      it 'skips the remote /flags call when flag_keys are all resolved locally' do
        stub_request(:get, %r{https://us\.i\.posthog\.com/flags/definitions})
          .to_return(status: 200, body: local_definitions.to_json)
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
        snapshot = c.evaluate_flags('user-1', flag_keys: %w[local-flag])
        expect(snapshot.keys).to eq(['local-flag'])
        expect(snapshot.get_flag('local-flag')).to be(true)
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
      end

      it 'still hits /flags when flag_keys is not provided (server may have unknown flags)' do
        stub_request(:get, %r{https://us\.i\.posthog\.com/flags/definitions})
          .to_return(status: 200, body: local_definitions.to_json)
        stub_flags(flags_response)
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
        c.evaluate_flags('user-1')
        expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).once
      end
    end

    describe 'disable_geoip' do
      it 'forwards disable_geoip: as geoip_disable in the /flags request body' do
        stub_flags(flags_response)
        client.evaluate_flags('user-1', disable_geoip: true)
        expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).with(
          body: hash_including(geoip_disable: true)
        )
      end
    end

    describe 'payload normalization' do
      it 'parses JSON-encoded payloads from the /flags response' do
        stub_flags(flags_response)
        snapshot = client.evaluate_flags('user-1')
        expect(snapshot.get_flag_payload('variant-flag')).to eq('key' => 'value')
      end
    end

    # Mirrors the @unresolved_flags_capable scenarios of the evaluate-flags spec.
    describe 'unresolved flags' do
      let(:definitions_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
      let(:plan_is_pro) { { key: 'plan', operator: 'exact', value: 'pro', type: 'person' } }
      let(:static_cohort) { { key: 'id', value: 42, type: 'cohort' } }
      let(:beta_ui) { flag_definition('beta-ui') }
      let(:checkout_with_continuity) { flag_definition('checkout', ensure_experience_continuity: true) }

      def flag_definition(key, *properties, **extra)
        { id: 1, key: key, active: true, filters: { groups: [{ properties: properties, rollout_percentage: 100 }] } }
          .merge(extra)
      end

      def depends_on(key)
        { key: key, type: 'flag', value: true, operator: 'flag_evaluates_to', dependency_chain: [key] }
      end

      def local_client(*flags)
        stub_request(:get, definitions_endpoint).to_return(status: 200, body: { flags: flags }.to_json)
        Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
      end

      def flag_called_events(client)
        drain_messages(client)
          .select { |m| m[:event] == '$feature_flag_called' }
          .to_h { |m| [m[:properties]['$feature_flag'], m[:properties]] }
      end

      it 'reports an experience continuity flag as unresolved in local-only evaluation' do
        c = local_client(beta_ui, checkout_with_continuity)

        snapshot = c.evaluate_flags('user-123', only_evaluate_locally: true)

        expect(snapshot.keys).to eq(['beta-ui'])
        expect(snapshot.unresolved_flags).to eq('checkout' => UnresolvedFlagReason::EXPERIENCE_CONTINUITY)
        expect(snapshot.unresolved_flags).to be_frozen
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
        expect(flag_called_events(c)).to eq({})
        expect(snapshot.only_accessed.keys).to eq([])
        expect(snapshot.only(%w[beta-ui checkout]).unresolved_flags).to eq({})
        expect(snapshot.get_flag('beta-ui')).to be(true)
      end

      # The spec's device-id row does not apply: this SDK has no device-id bucketing.
      [
        ['a missing person property', :plan_only, {}, UnresolvedFlagReason::MISSING_CONTEXT],
        ['an operator this SDK does not recognize', :unknown_operator, { plan: 'enterprise' },
         UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
        ['a static cohort', :static_cohort_only, {}, UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
        ['a static cohort and a missing person property', :static_cohort_and_plan, {},
         UnresolvedFlagReason::UNSUPPORTED_DEFINITION],
        ['a missing person property and a static cohort', :plan_and_static_cohort, {},
         UnresolvedFlagReason::UNSUPPORTED_DEFINITION]
      ].each do |cause, filters, person_properties, reason|
        it "reports #{reason} for #{cause}" do
          properties = {
            plan_only: [plan_is_pro],
            unknown_operator: [{ key: 'plan', operator: 'bogus', value: 'x', type: 'person' }],
            static_cohort_only: [static_cohort],
            static_cohort_and_plan: [static_cohort, plan_is_pro],
            plan_and_static_cohort: [plan_is_pro, static_cohort]
          }.fetch(filters)
          c = local_client(flag_definition('checkout', *properties, ensure_experience_continuity: false))

          snapshot = c.evaluate_flags('user-123', person_properties: person_properties, only_evaluate_locally: true)

          expect(snapshot.keys).not_to include('checkout')
          expect(snapshot.unresolved_flags).to eq('checkout' => reason)
        end
      end

      it 'reports a flag blocked by an unresolved dependency as unresolved_dependency' do
        c = local_client(checkout_with_continuity, flag_definition('beta-ui', depends_on('checkout')))

        snapshot = c.evaluate_flags('user-123', flag_keys: ['beta-ui'], only_evaluate_locally: true)

        expect(snapshot.keys).not_to include('beta-ui')
        expect(snapshot.unresolved_flags).to eq('beta-ui' => UnresolvedFlagReason::UNRESOLVED_DEPENDENCY)
      end

      it 'reports the dependency with its own reason when it is in scope' do
        c = local_client(flag_definition('checkout', plan_is_pro), flag_definition('beta-ui', depends_on('checkout')))

        snapshot = c.evaluate_flags('user-123', only_evaluate_locally: true)

        expect(snapshot.unresolved_flags).to eq(
          'checkout' => UnresolvedFlagReason::MISSING_CONTEXT,
          'beta-ui' => UnresolvedFlagReason::UNRESOLVED_DEPENDENCY
        )
      end

      context 'when a flag depends on a flag that needs the server' do
        let(:static_cohort_dep) { flag_definition('dep', { key: 'id', type: 'cohort', value: 999 }) }
        let(:target) do
          {
            id: 2, key: 'target', active: true,
            filters: {
              multivariate: { variants: [{ key: 'a', rollout_percentage: 50 }, { key: 'b', rollout_percentage: 50 }] },
              groups: [
                { properties: [depends_on('dep')], rollout_percentage: 100, variant: 'a' },
                { properties: [], rollout_percentage: 100, variant: 'b' }
              ]
            }
          }
        end

        [['target alone', { flag_keys: ['target'] }], ['all flags', {}]].each do |description, options|
          it "uses the server value with #{description} requested" do
            c = local_client(static_cohort_dep, target)
            stub_flags(flags: { 'target' => { key: 'target', enabled: true, variant: 'a' } })

            snapshot = c.evaluate_flags('user-123', **options)

            expect(snapshot.get_flag('target')).to eq('a')
            expect(WebMock).to have_requested(:post, FLAGS_ENDPOINT).once
          end
        end

        it 'leaves the flag unresolved in local-only evaluation' do
          c = local_client(static_cohort_dep, target)

          snapshot = c.evaluate_flags('user-123', flag_keys: ['target'], only_evaluate_locally: true)

          expect(snapshot.keys).not_to include('target')
          expect(snapshot.unresolved_flags).to eq('target' => UnresolvedFlagReason::UNRESOLVED_DEPENDENCY)
        end

        it 'resolves the flag locally when the dependency resolves locally' do
          c = local_client(flag_definition('dep', plan_is_pro), target)

          snapshot = c.evaluate_flags('user-123', person_properties: { plan: 'pro' }, flag_keys: ['target'])

          expect(snapshot.get_flag('target')).to eq('a')
          expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
        end
      end

      it 'reports a flag that depends on a flag with no loaded definition as unsupported_definition' do
        c = local_client(flag_definition('beta-ui', depends_on('checkout')))

        snapshot = c.evaluate_flags('user-123', flag_keys: ['beta-ui'], only_evaluate_locally: true)

        expect(snapshot.keys).not_to include('beta-ui')
        expect(snapshot.unresolved_flags).to eq('beta-ui' => UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end

      it 'does not report a flag the remote fallback resolved' do
        c = local_client(checkout_with_continuity)
        stub_flags(flags: { 'checkout' => { key: 'checkout', enabled: true, variant: nil } })

        snapshot = c.evaluate_flags('user-123')

        expect(snapshot.get_flag('checkout')).to be(true)
        expect(snapshot.unresolved_flags).to eq({})
      end

      {
        'the remote request fails' => -> { stub_request(:post, FLAGS_ENDPOINT).to_return(status: 500, body: '{}') },
        'the remote request raises' => -> { stub_request(:post, FLAGS_ENDPOINT).to_raise(Errno::ECONNREFUSED) },
        'the remote response returns no flags' => -> { stub_flags(flags: {}) },
        'the remote response marks the flag as failed' => lambda {
          stub_flags(
            flags: { 'checkout' => { key: 'checkout', enabled: false, variant: nil, failed: true } },
            errorsWhileComputingFlags: true
          )
        }
      }.each do |outcome, stub_outcome|
        it "leaves the flag unresolved when #{outcome}" do
          c = local_client(checkout_with_continuity)
          instance_exec(&stub_outcome)

          snapshot = c.evaluate_flags('user-123')

          expect(snapshot.keys).not_to include('checkout')
          expect(snapshot.unresolved_flags).to eq('checkout' => UnresolvedFlagReason::EXPERIENCE_CONTINUITY)
          expect(snapshot.enabled?('checkout')).to be(false)
          error = flag_called_events(c)['checkout']['$feature_flag_error']
          expect(error.split(',')).to include('local_evaluation_inconclusive')
          expect(error.split(',')).not_to include('flag_missing')
        end
      end

      it 'keeps a failed remote flag without a local definition as false' do
        c = local_client(beta_ui)
        stub_flags(
          flags: { 'remote-only' => { key: 'remote-only', enabled: false, variant: nil, failed: true } },
          errorsWhileComputingFlags: true
        )

        snapshot = c.evaluate_flags('user-123')

        expect(snapshot.keys).to include('remote-only')
        expect(snapshot.get_flag('remote-only')).to be(false)
        expect(snapshot.unresolved_flags).to eq({})
      end

      it 'reports a key without a local definition as missing, not unresolved' do
        c = local_client(beta_ui)
        stub_flags(flags: {})

        snapshot = c.evaluate_flags('user-123', flag_keys: %w[beta-ui typo-flag])
        snapshot.enabled?('typo-flag')

        expect(snapshot.unresolved_flags).to eq({})
        expect(flag_called_events(c)['typo-flag']['$feature_flag_error']).to eq('flag_missing')
      end

      it 'does not report a flag outside the requested keys' do
        c = local_client(beta_ui, checkout_with_continuity)

        snapshot = c.evaluate_flags('user-123', flag_keys: ['beta-ui'])

        expect(snapshot.keys).to eq(['beta-ui'])
        expect(snapshot.get_flag('beta-ui')).to be(true)
        expect(snapshot.unresolved_flags).to eq({})
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
      end

      it 'resolves an inactive flag with experience continuity to false' do
        c = local_client(checkout_with_continuity.merge(active: false))

        snapshot = c.evaluate_flags('user-123', only_evaluate_locally: true)

        expect(snapshot.keys).to eq(['checkout'])
        expect(snapshot.get_flag('checkout')).to be(false)
        expect(snapshot.unresolved_flags).to eq({})
      end

      it 'reports no error when reading a flag the remote fallback resolved' do
        c = local_client(checkout_with_continuity)
        stub_flags(flags: { 'checkout' => { key: 'checkout', enabled: true, variant: nil } })

        snapshot = c.evaluate_flags('user-123')

        expect(snapshot.enabled?('checkout')).to be(true)
        properties = flag_called_events(c)['checkout']
        expect(properties['$feature_flag_response']).to be(true)
        expect(properties).not_to have_key('$feature_flag_error')
      end

      it 'reports local_evaluation_inconclusive when reading an unresolved flag' do
        c = local_client(checkout_with_continuity)

        snapshot = c.evaluate_flags('user-123', only_evaluate_locally: true)

        expect(snapshot.enabled?('checkout')).to be(false)
        expect(flag_called_events(c)['checkout']['$feature_flag_error']).to eq('local_evaluation_inconclusive')
      end

      it 'keeps response-level errors next to local_evaluation_inconclusive' do
        c = local_client(checkout_with_continuity)
        stub_flags(flags: {}, errorsWhileComputingFlags: true)

        c.evaluate_flags('user-123').enabled?('checkout')

        expect(flag_called_events(c)['checkout']['$feature_flag_error'])
          .to eq('errors_while_computing_flags,local_evaluation_inconclusive')
      end

      it 'carries no unresolved flags on filtered snapshots' do
        c = local_client(beta_ui, checkout_with_continuity)
        snapshot = c.evaluate_flags('user-123', only_evaluate_locally: true)
        snapshot.enabled?('beta-ui')

        expect(snapshot.only_accessed.unresolved_flags).to eq({})
        filtered = snapshot.only(['beta-ui'])
        expect(filtered.unresolved_flags).to eq({})
        filtered.get_flag('checkout')
        expect(flag_called_events(c)['checkout']['$feature_flag_error']).to eq('flag_missing')
        expect(snapshot.unresolved_flags).to eq('checkout' => UnresolvedFlagReason::EXPERIENCE_CONTINUITY)
      end

      it 'does not report a flag that fails with an unexpected error' do
        c = local_client(flag_definition('checkout').merge(filters: { groups: [{ properties: 'oops' }] }))

        snapshot = c.evaluate_flags('user-123', only_evaluate_locally: true)
        snapshot.enabled?('checkout')

        expect(snapshot.unresolved_flags).to eq({})
        expect(flag_called_events(c)['checkout']['$feature_flag_error']).to eq('flag_missing')
      end

      it 'resolves a flag locally when a filter does not match next to one local evaluation cannot check' do
        free_plan = { key: 'plan', operator: 'exact', value: 'free', type: 'person' }
        c = local_client(flag_definition('checkout', static_cohort, free_plan))

        snapshot = c.evaluate_flags('user-123', person_properties: { plan: 'pro' }, flag_keys: ['checkout'])

        expect(snapshot.get_flag('checkout')).to be(false)
        expect(snapshot.unresolved_flags).to eq({})
        expect(WebMock).not_to have_requested(:post, FLAGS_ENDPOINT)
      end
    end
  end
end
