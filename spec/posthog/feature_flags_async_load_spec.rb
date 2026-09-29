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
    let(:release) { Queue.new }

    after do
      release.close
      if @caller
        @caller.kill unless @caller.join(2)
        @caller.join
      end
      @client&.shutdown
    end

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

    describe 'Client.new' do
      it 'returns immediately, fetching flag definitions asynchronously' do
        started = Queue.new
        stub_request(:get, definitions_endpoint).to_return do
          started << true
          release.pop
          { status: 200, body: definitions_body }
        end

        @caller = Thread.new { build_client }
        eventually { expect(started).not_to be_empty }
        expect(@caller.join(1)).to eq(@caller)
        client = @caller.value
        expect(client.feature_flags_loaded?).to be(false)

        release << true
        eventually { expect(client.feature_flags_loaded?).to be(true) }
        expect(local_flag_value(client)).to be(true)
      end

      it 'keeps the default synchronous load when the option is not set' do
        fetch_thread = nil
        stub_request(:get, definitions_endpoint).to_return do
          fetch_thread = Thread.current
          { status: 200, body: definitions_body }
        end

        client = @client = Client.new(api_key: API_KEY, secret_key: API_KEY, test_mode: true)

        expect(fetch_thread).to eq(Thread.current)
        expect(client.feature_flags_loaded?).to be(true)
        expect(local_flag_value(client)).to be(true)
      end
    end

    describe 'Client#evaluate_flags before definitions have loaded' do
      it 'returns nil without blocking or fetching definitions' do
        fetches_started = Concurrent::AtomicFixnum.new(0)
        stub_request(:get, definitions_endpoint).to_return do
          fetches_started.increment
          release.pop
          { status: 200, body: definitions_body }
        end

        client = build_client
        eventually { expect(fetches_started.value).to eq(1) }
        @caller = Thread.new { Array.new(3) { local_flag_value(client) } }

        expect(@caller.join(1)).to eq(@caller)
        expect(@caller.value).to eq([nil, nil, nil])
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
            release.pop
            { status: 200, body: definitions_body }
          end
        end

        client = build_client(feature_flags_polling_interval: 0.2)
        eventually { expect(attempts.value).to be >= 2 }
        expect(client.feature_flags_loaded?).to be(false)
        expect(local_flag_value(client)).to be_nil

        release.close
        eventually { expect(client.feature_flags_loaded?).to be(true) }
        expect(local_flag_value(client)).to be(true)
      end
    end

    describe 'Client#reload_feature_flags' do
      it 'still fetches synchronously on the calling thread' do
        stub_request(:get, definitions_endpoint).to_return(status: 200, body: definitions_body)
        client = build_client
        eventually { expect(client.feature_flags_loaded?).to be(true) }

        fetch_thread = nil
        stub_request(:get, definitions_endpoint).to_return do
          fetch_thread = Thread.current
          { status: 200, body: { flags: [beta_flag_definition.merge(key: 'newer-feature')] }.to_json }
        end

        client.reload_feature_flags

        expect(fetch_thread).to eq(Thread.current)
        expect(local_flag_value(client, 'newer-feature')).to be(true)
      end
    end

    describe 'Client#feature_flags_loaded?' do
      it 'is false without a secret_key' do
        client = @client = Client.new(api_key: API_KEY, test_mode: true)
        expect(client.feature_flags_loaded?).to be(false)
      end

      it 'becomes false again when a 402 quota-limited response discards the definitions' do
        stub_request(:get, definitions_endpoint).to_return(status: 200, body: definitions_body)
        client = build_client
        eventually { expect(client.feature_flags_loaded?).to be(true) }

        stub_request(:get, definitions_endpoint)
          .to_return(status: 402, body: { error: 'quota_limit_exceeded' }.to_json)
        client.reload_feature_flags

        expect(client.feature_flags_loaded?).to be(false)
      end
    end
  end
end
