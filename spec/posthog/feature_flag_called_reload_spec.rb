# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe 'feature flag called tracking across definition reloads' do
    let(:definitions_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:flag_definition) do
      {
        id: 1,
        key: 'beta-feature',
        active: true,
        version: 1,
        filters: { groups: [{ properties: [], rollout_percentage: 100 }] }
      }
    end
    let(:definitions) { { flags: [flag_definition] } }
    let(:client) { @client || build_client }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }

    before do
      stub_request(:get, definitions_endpoint).to_return(status: 200, body: definitions.to_json)
    end

    after { @client&.shutdown }

    def build_client(**opts)
      @client = Client.new(
        api_key: API_KEY,
        secret_key: API_KEY,
        test_mode: true,
        feature_flag_request_max_retries: 0,
        **opts
      )
    end

    def read_flag
      client.get_feature_flag('beta-feature', 'user', only_evaluate_locally: true)
    end

    def expect_single_event
      expect(client.queued_messages).to eq(1)
      expect(client.dequeue_last_message[:event]).to eq('$feature_flag_called')
    end

    it 'emits once per user and flag response between successful manual reloads' do
      2.times { expect(read_flag).to be(true) }
      expect_single_event

      client.reload_feature_flags

      2.times { expect(read_flag).to be(true) }
      expect_single_event
    end

    it 'resets the shared tracker for both snapshot and single-flag access' do
      snapshot = client.evaluate_flags('user', only_evaluate_locally: true)
      expect(snapshot.get_flag('beta-feature')).to be(true)
      expect(read_flag).to be(true)
      expect_single_event

      client.reload_feature_flags

      expect(snapshot.get_flag('beta-feature')).to be(true)
      expect(read_flag).to be(true)
      expect_single_event
    end

    it 'resets tracking on an automatic background refresh' do
      refresh_allowed = Queue.new
      requests = Concurrent::AtomicFixnum.new(0)
      stub_request(:get, definitions_endpoint).to_return do
        case requests.increment
        when 1
          { status: 200, body: definitions.to_json }
        when 2
          refresh_allowed.pop
          { status: 200, body: { flags: [flag_definition.merge(version: 2)] }.to_json }
        else
          { status: 304, body: '' }
        end
      end
      build_client(feature_flags_polling_interval: 0.1)
      2.times { expect(read_flag).to be(true) }
      expect_single_event

      refresh_allowed << true

      eventually do
        expect(read_flag).to be(true)
        expect(client.queued_messages).to eq(1)
      end
      expect_single_event
      expect(poller.feature_flags_by_key['beta-feature'][:version]).to eq(2)
      2.times { expect(read_flag).to be(true) }
      expect(client.queued_messages).to eq(0)
    ensure
      refresh_allowed&.push(true)
    end

    it 'resets tracking when definitions are applied from the external cache' do
      provider = double(
        'cache provider',
        should_fetch_flag_definitions?: true,
        on_flag_definitions_received: nil,
        shutdown: nil,
        flag_definitions: definitions
      )
      build_client(flag_definition_cache_provider: provider)
      2.times { expect(read_flag).to be(true) }
      expect_single_event
      allow(provider).to receive(:should_fetch_flag_definitions?).and_return(false)

      poller._load_feature_flags

      2.times { expect(read_flag).to be(true) }
      expect_single_event
      expect(WebMock).to have_requested(:get, definitions_endpoint).once
    end

    it 'resets tracking when an empty definitions response is applied' do
      2.times { client.get_feature_flag('missing', 'user', only_evaluate_locally: true) }
      expect_single_event
      stub_request(:get, definitions_endpoint).to_return(status: 200, body: { flags: [] }.to_json)

      client.reload_feature_flags

      2.times { client.get_feature_flag('missing', 'user', only_evaluate_locally: true) }
      expect_single_event
    end

    it 'resets tracking when a quota-limited response discards definitions' do
      2.times { client.get_feature_flag('missing', 'user', only_evaluate_locally: true) }
      expect_single_event
      stub_request(:get, definitions_endpoint).to_return(status: 402, body: '{}')

      client.reload_feature_flags

      expect(client.feature_flags_loaded?).to be(false)
      2.times { client.get_feature_flag('missing', 'user', only_evaluate_locally: true) }
      expect_single_event
    end

    [
      { status: 304, body: '' },
      { status: 500, body: '{}' },
      { status: 200, body: '{}' },
      { status: 200, body: 'invalid json' }
    ].each do |response|
      it "preserves tracking when no definitions are applied (#{response})" do
        2.times { expect(read_flag).to be(true) }
        expect_single_event
        stub_request(:get, definitions_endpoint).to_return(response)

        client.reload_feature_flags

        2.times { expect(read_flag).to be(true) }
        expect(client.queued_messages).to eq(0)
      end
    end

    it 'preserves tracking when the reload request times out' do
      expect(read_flag).to be(true)
      expect_single_event
      stub_request(:get, definitions_endpoint).to_timeout

      client.reload_feature_flags

      expect(read_flag).to be(true)
      expect(client.queued_messages).to eq(0)
    end

    it 'clears tracking under the same mutex used to suppress duplicates' do
      expect(read_flag).to be(true)
      tracker = client.instance_variable_get(:@distinct_id_has_sent_flag_calls)
      mutex = client.instance_variable_get(:@distinct_id_has_sent_flag_calls_mutex)
      allow(tracker).to receive(:clear).and_wrap_original do |clear|
        expect(mutex.owned?).to be(true)
        clear.call
      end

      client.reload_feature_flags

      expect(tracker).to have_received(:clear).once
    end

    it 'continues suppressing concurrent duplicate reads after reload' do
      expect(read_flag).to be(true)
      expect_single_event
      client.reload_feature_flags
      start = Queue.new
      threads = Array.new(4) do
        Thread.new do
          start.pop
          5.times { read_flag }
        end
      end
      threads.length.times { start << true }
      threads.each do |thread|
        expect(thread.join(2)).to eq(thread)
        thread.value
      end

      expect_single_event
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
    end
  end
end
