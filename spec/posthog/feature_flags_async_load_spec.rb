# frozen_string_literal: true

require 'spec_helper'
require 'posthog/client'

module PostHog
  describe 'feature_flags_async_load' do
    let(:definitions_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:beta_flag_definition) do
      {
        id: 1,
        name: 'Beta Feature',
        key: 'beta-feature',
        active: true,
        filters: { groups: [{ properties: [], rollout_percentage: 100 }] }
      }
    end
    let(:definitions_body) { { flags: [beta_flag_definition] }.to_json }

    # Stop the poller so it doesn't keep hitting (reset) WebMock stubs for the
    # rest of the suite.
    after { @client&.shutdown }

    def build_client(**opts)
      @client = Client.new(
        api_key: API_KEY,
        secret_key: API_KEY,
        test_mode: true,
        feature_flag_request_max_retries: 0,
        feature_flags_async_load: true,
        **opts
      )
    end

    def local_flag_value(client, key = 'beta-feature')
      client.evaluate_flags('distinct-id', only_evaluate_locally: true).get_flag(key)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    describe 'Client.new' do
      it 'returns immediately, fetching flag definitions asynchronously' do
        stub_request(:get, definitions_endpoint).to_return do
          sleep 1
          { status: 200, body: definitions_body }
        end

        started = monotonic_now
        client = build_client
        elapsed = monotonic_now - started

        expect(elapsed).to be < 0.5

        # no flag definitions yet
        expect(client.feature_flags_loaded?).to be(false)

        # flag definitions loaded later, asynchronously
        eventually { expect(client.feature_flags_loaded?).to be(true) }
        expect(local_flag_value(client)).to be(true)
      end

      it 'keeps the default synchronous load when the option is not set' do
        stub_request(:get, definitions_endpoint).to_return do
          sleep 0.3
          { status: 200, body: definitions_body }
        end

        started = monotonic_now
        client = @client = Client.new(api_key: API_KEY, secret_key: API_KEY, test_mode: true)
        elapsed = monotonic_now - started

        expect(elapsed).to be >= 0.3
        expect(client.feature_flags_loaded?).to be(true)
        expect(local_flag_value(client)).to be(true)
      end
    end

    describe 'Client#evaluate_flags before definitions have loaded' do
      it 'returns nil without blocking or fetching definitions' do
        fetches_started = Concurrent::AtomicFixnum.new(0)
        stub_request(:get, definitions_endpoint).to_return do
          fetches_started.increment
          sleep 1
          { status: 200, body: definitions_body }
        end

        client = build_client
        eventually { expect(fetches_started.value).to eq(1) }

        started = monotonic_now
        values = Array.new(3) { local_flag_value(client) }
        elapsed = monotonic_now - started

        # the poller's initial load is still sleeping in the stub
        expect(values).to eq([nil, nil, nil])
        expect(elapsed).to be < 0.5
        expect(fetches_started.value).to eq(1)
      end
    end

    describe 'definitions loading, when the initial load fails' do
      it 'recovers on the polling cadence' do
        attempts = Concurrent::AtomicFixnum.new(0)
        stub_request(:get, definitions_endpoint).to_return do
          if attempts.increment == 1
            { status: 500, body: 'error' }
          else
            { status: 200, body: definitions_body }
          end
        end

        client = build_client(feature_flags_polling_interval: 0.2)

        expect(local_flag_value(client)).to be_nil
        eventually { expect(client.feature_flags_loaded?).to be(true) }
        expect(local_flag_value(client)).to be(true)
        expect(attempts.value).to be >= 2
      end
    end

    describe 'Client#reload_feature_flags' do
      it 'still fetches synchronously on the calling thread' do
        stub_request(:get, definitions_endpoint).to_return(status: 200, body: definitions_body)
        client = build_client
        eventually { expect(client.feature_flags_loaded?).to be(true) }

        stub_request(:get, definitions_endpoint).to_return do
          sleep 0.3
          { status: 200, body: { flags: [beta_flag_definition.merge(key: 'newer-feature')] }.to_json }
        end

        started = monotonic_now
        client.reload_feature_flags
        elapsed = monotonic_now - started

        expect(elapsed).to be >= 0.3
        expect(local_flag_value(client, 'newer-feature')).to be(true)
      end
    end

    describe 'Client#feature_flags_loaded?' do
      it 'is false without a secret_key' do
        client = @client = Client.new(api_key: API_KEY, test_mode: true)
        expect(client.feature_flags_loaded?).to be(false)
      end
    end
  end
end
