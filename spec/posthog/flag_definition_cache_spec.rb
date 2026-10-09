# frozen_string_literal: true

require 'spec_helper'

# MockCacheProvider is scoped outside PostHog module to avoid polluting the production namespace.
class MockCacheProvider
  attr_accessor :stored_data, :should_fetch_return_value,
                :should_fetch_error, :get_error, :on_received_error, :shutdown_error
  attr_reader :get_call_count, :should_fetch_call_count, :on_received_call_count, :shutdown_call_count

  def initialize
    @stored_data = nil
    @should_fetch_return_value = true
    @get_call_count = 0
    @should_fetch_call_count = 0
    @on_received_call_count = 0
    @shutdown_call_count = 0
    @should_fetch_error = nil
    @get_error = nil
    @on_received_error = nil
    @shutdown_error = nil
  end

  def flag_definitions
    @get_call_count += 1
    raise @get_error if @get_error

    @stored_data
  end

  def should_fetch_flag_definitions?
    @should_fetch_call_count += 1
    raise @should_fetch_error if @should_fetch_error

    @should_fetch_return_value
  end

  def on_flag_definitions_received(data)
    @on_received_call_count += 1
    raise @on_received_error if @on_received_error

    @stored_data = data
  end

  def shutdown
    @shutdown_call_count += 1
    raise @shutdown_error if @shutdown_error
  end
end

module PostHog
  describe FlagDefinitionCacheProvider do
    describe '.validate!' do
      it 'passes for a complete provider' do
        provider = MockCacheProvider.new
        expect { FlagDefinitionCacheProvider.validate!(provider) }.not_to raise_error
      end

      it 'raises ArgumentError for an object missing all methods' do
        provider = Object.new
        expect { FlagDefinitionCacheProvider.validate!(provider) }.to raise_error(
          ArgumentError,
          /missing required methods.*(flag_definitions|should_fetch|on_flag|shutdown)/
        )
      end

      it 'raises ArgumentError listing only the missing methods' do
        provider = Object.new
        def provider.flag_definitions; end
        def provider.shutdown; end

        expect { FlagDefinitionCacheProvider.validate!(provider) }.to raise_error(ArgumentError) do |error|
          # Extract and parse the missing methods list
          missing_str = error.message.split('missing required methods: ').last.split('.').first
          missing_methods = missing_str.split(', ').map(&:strip)
          expect(missing_methods).to include('should_fetch_flag_definitions?')
          expect(missing_methods).to include('on_flag_definitions_received')
          # Verify the implemented methods are NOT listed as missing
          expect(missing_methods).not_to include('flag_definitions')
          expect(missing_methods).not_to include('shutdown')
        end
      end
    end
  end

  describe 'flag definition cache integration' do
    let(:provider) { MockCacheProvider.new }
    let(:local_eval_url) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }

    # Sample flag data with string keys (simulating JSON deserialization from cache)
    let(:sample_flags_data) do
      {
        'flags' => [
          {
            'id' => 1,
            'key' => 'test-flag',
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [
                    { 'key' => 'region', 'operator' => 'exact', 'value' => ['USA'], 'type' => 'person' }
                  ],
                  'rollout_percentage' => 100
                }
              ]
            }
          },
          { 'id' => 2, 'key' => 'disabled-flag', 'active' => false, 'filters' => {} }
        ],
        'group_type_mapping' => { '0' => 'company', '1' => 'project' },
        'cohorts' => { '1' => { 'type' => 'AND', 'values' => [] } }
      }
    end

    def create_client_with_cache(provider:, stub_api: true)
      if stub_api
        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
      end
      Client.new(
        api_key: API_KEY,
        personal_api_key: API_KEY,
        test_mode: true,
        flag_definition_cache_provider: provider
      )
    end

    def get_poller(client)
      client.instance_variable_get(:@feature_flags_poller)
    end

    describe 'cache consumers without a secret key' do
      let(:definitions_request) do
        stub_request(:get, local_eval_url).to_return(status: 200, body: sample_flags_data.to_json)
      end
      let(:flags_request) do
        stub_request(:post, 'https://us.i.posthog.com/flags/?v=2')
          .to_return(status: 200, body: { featureFlags: {} }.to_json)
      end
      let(:disabled_flags_data) do
        sample_flags_data.merge('flags' => sample_flags_data['flags'].map { |flag| flag.merge('active' => false) })
      end

      before do
        definitions_request
        flags_request
        provider.should_fetch_return_value = false
        provider.stored_data = sample_flags_data
      end

      after do
        @client&.shutdown
        expect(definitions_request).not_to have_been_requested
        expect(flags_request).not_to have_been_requested
      end

      def build_cache_consumer(**opts)
        @client = Client.new(
          api_key: API_KEY,
          test_mode: true,
          flag_definition_cache_provider: provider,
          **opts
        )
      end

      def cached_flag_value(client, only_evaluate_locally: false)
        client.evaluate_flags(
          'some-user',
          flag_keys: ['test-flag'],
          person_properties: { 'region' => 'USA' },
          only_evaluate_locally: only_evaluate_locally
        ).get_flag('test-flag')
      end

      it 'loads cached definitions at construction and evaluates through public entry points' do
        expect(provider).to receive(:should_fetch_flag_definitions?).ordered.and_call_original
        expect(provider).to receive(:flag_definitions).ordered.and_call_original
        client = build_cache_consumer

        expect(client.feature_flags_loaded?).to be(true)
        expect(cached_flag_value(client)).to be(true)
        expect(client.get_feature_flag('disabled-flag', 'some-user')).to be(false)
        expect(client.get_feature_flag('test-flag', 'some-user', person_properties: { region: 'USA' })).to be(true)
        expect(client.get_all_flags('some-user', person_properties: { region: 'USA' }))
          .to eq('test-flag' => true, 'disabled-flag' => false)
        expect(provider.get_call_count).to eq(1)
        expect(provider.on_received_call_count).to eq(0)
      end

      it 'refreshes definitions synchronously through public reload' do
        client = build_cache_consumer
        expect(cached_flag_value(client)).to be(true)
        provider.stored_data = disabled_flags_data

        client.reload_feature_flags

        expect(provider.get_call_count).to eq(2)
        expect(cached_flag_value(client)).to be(false)
      end

      it 'refreshes cached definitions through the existing polling task and stops on shutdown' do
        client = build_cache_consumer(feature_flags_polling_interval: 0.05)
        provider.stored_data = disabled_flags_data

        eventually { expect(cached_flag_value(client)).to be(false) }
        expect(provider.get_call_count).to be >= 2
        client.shutdown
        expect(provider.shutdown_call_count).to eq(1)
        expect(get_poller(client).instance_variable_get(:@task).running?).to be(false)
      end

      it 'loads cached definitions on the background thread when async loading is enabled' do
        release = Queue.new
        started = Queue.new
        fetch_thread = nil
        allow(provider).to receive(:flag_definitions) do
          fetch_thread = Thread.current
          started << true
          release.pop
          sample_flags_data
        end
        client = build_cache_consumer(feature_flags_async_load: true)
        eventually { expect(started).not_to be_empty }

        expect(client.feature_flags_loaded?).to be(false)
        expect(cached_flag_value(client, only_evaluate_locally: true)).to be_nil
        expect(fetch_thread).not_to eq(Thread.current)
        release << true
        eventually { expect(client.feature_flags_loaded?).to be(true) }
        expect(cached_flag_value(client)).to be(true)
      ensure
        release&.close
      end

      it 'retries loading on first evaluation after an initial cache miss' do
        provider.stored_data = nil
        client = build_cache_consumer
        expect(client.feature_flags_loaded?).to be(false)
        provider.stored_data = sample_flags_data

        expect(cached_flag_value(client)).to be(true)
        expect(client.feature_flags_loaded?).to be(true)
        expect(provider.get_call_count).to eq(2)
      end

      {
        'cache miss' => proc { |cache| cache.stored_data = nil },
        'cache read failure' => proc { |cache| cache.get_error = RuntimeError.new('Redis timeout') },
        'positive fetch decision' => proc { |cache| cache.should_fetch_return_value = true },
        'fetch decision failure' => proc { |cache| cache.should_fetch_error = RuntimeError.new('Redis unavailable') }
      }.each do |scenario, configure_provider|
        it "skips direct fetches and warns on an initial #{scenario}" do
          configure_provider.call(provider)
          expect(Logging.logger).to receive(:warn).with(/secret_key.*fetch flag definitions/)
          client = build_cache_consumer

          expect(client.feature_flags_loaded?).to be(false)
          expect(provider.get_call_count).to eq(scenario.include?('decision') ? 0 : 1)
          expect(provider.on_received_call_count).to eq(0)
        end

        it "preserves the last snapshot on reload after a #{scenario}" do
          provider.stored_data = sample_flags_data.merge('property_matching_version' => 2)
          client = build_cache_consumer
          configure_provider.call(provider)
          reads_before_reload = provider.get_call_count

          client.reload_feature_flags

          expect(client.feature_flags_loaded?).to be(true)
          expect(cached_flag_value(client)).to be(true)
          expect(get_poller(client)._evaluation_snapshot[:property_matching_version]).to eq(2)
          expect(provider.get_call_count).to eq(reads_before_reload) if scenario.include?('decision')
          expect(provider.on_received_call_count).to eq(0)
        end
      end

      it 'hydrates matching metadata and resets to legacy when a fresh snapshot omits the version' do
        data = sample_flags_data.merge('property_matching_version' => 2)
        data['flags'] = [{
          'key' => 'versioned-flag', 'active' => true,
          'filters' => { 'groups' => [{ 'properties' => [{ 'key' => 'value', 'value' => false }] }] }
        }]
        provider.stored_data = data
        client = build_cache_consumer
        expect(client.get_feature_flag('versioned-flag', 'user', person_properties: { value: 'banana' })).to be(false)

        provider.stored_data = data.except('property_matching_version')
        client.reload_feature_flags

        expect(client.get_feature_flag('versioned-flag', 'user', person_properties: { value: 'banana' })).to be(true)
      end

      it 'does not consult the provider without a project API key' do
        client = build_cache_consumer(api_key: nil)
        client.reload_feature_flags

        expect(client.feature_flags_loaded?).to be(false)
        expect(provider.should_fetch_call_count).to eq(0)
      end

      it 'keeps local evaluation disabled without either a secret key or a provider' do
        client = build_cache_consumer(flag_definition_cache_provider: nil)
        client.reload_feature_flags

        expect(client.feature_flags_loaded?).to be(false)
        expect(cached_flag_value(client, only_evaluate_locally: true)).to be_nil
        expect(get_poller(client).instance_variable_get(:@task).running?).to be(false)
      end
    end

    describe 'cache initialization' do
      it 'uses cached data when should_fetch? returns false and cache has data' do
        provider.should_fetch_return_value = false
        provider.stored_data = sample_flags_data

        # The initial load_feature_flags call should use cache, not API
        stub = stub_request(:get, local_eval_url)
               .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        # API should not have been called (initial load uses cache)
        expect(stub).not_to have_been_requested

        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
        expect(provider.get_call_count).to be >= 1
      end

      it 'fetches from API when should_fetch? returns true' do
        provider.should_fetch_return_value = true

        stub = stub_request(:get, local_eval_url)
               .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        expect(stub).to have_been_requested
        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'uses emergency fallback when cache is empty and no flags loaded' do
        provider.should_fetch_return_value = false
        provider.stored_data = nil # Cache empty

        stub = stub_request(:get, local_eval_url)
               .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        # Should have fallen back to API
        expect(stub).to have_been_requested
        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'preserves existing flags when cache returns nil but flags already loaded' do
        provider.should_fetch_return_value = true

        stub = stub_request(:get, local_eval_url)
               .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)

        # Now simulate: should_fetch false, cache nil, but flags already loaded
        provider.should_fetch_return_value = false
        provider.stored_data = nil

        poller.send(:_load_feature_flags)
        # Flags should be preserved (no emergency fallback since flags exist)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
        # API should have been called only once (during init), not during the second load
        expect(stub).to have_been_requested.once
      end
    end

    describe 'fetch coordination' do
      it 'calls should_fetch? before each poll cycle' do
        provider.should_fetch_return_value = true

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider)

        initial_count = provider.should_fetch_call_count

        poller = get_poller(client)
        poller.send(:_load_feature_flags)

        expect(provider.should_fetch_call_count).to eq(initial_count + 1)
      end

      it 'stores data in cache after API fetch' do
        provider.should_fetch_return_value = true

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        create_client_with_cache(provider: provider)

        expect(provider.on_received_call_count).to be >= 1
        expect(provider.stored_data).not_to be_nil
        expect(provider.stored_data[:flags].length).to eq(2)
        expect(provider.stored_data[:group_type_mapping]).to be_a(Hash)
        expect(provider.stored_data[:cohorts]).to be_a(Hash)
      end

      it 'does not call on_flag_definitions_received when cache is used' do
        provider.should_fetch_return_value = true

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider)

        initial_on_received_count = provider.on_received_call_count

        # Now use cache
        provider.should_fetch_return_value = false

        poller = get_poller(client)
        poller.send(:_load_feature_flags)

        expect(provider.on_received_call_count).to eq(initial_on_received_count)
      end

      it 'does not update cache on 304 Not Modified' do
        provider.should_fetch_return_value = true

        # First call: return flags
        stub_request(:get, local_eval_url)
          .to_return(
            { status: 200, body: sample_flags_data.to_json, headers: { 'ETag' => 'abc123' } },
            { status: 304, body: '', headers: { 'ETag' => 'abc123' } }
          )
        client = create_client_with_cache(provider: provider, stub_api: false)

        on_received_after_init = provider.on_received_call_count

        # Second call: 304
        poller = get_poller(client)
        poller.send(:_load_feature_flags)

        expect(provider.on_received_call_count).to eq(on_received_after_init)
      end
    end

    describe 'error handling' do
      it 'defaults to fetching from API when should_fetch? raises' do
        provider.should_fetch_error = RuntimeError.new('Redis connection error')

        stub = stub_request(:get, local_eval_url)
               .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        expect(stub).to have_been_requested
        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'falls back to API fetch when flag_definitions raises' do
        provider.should_fetch_return_value = false
        provider.get_error = RuntimeError.new('Redis timeout')

        stub = stub_request(:get, local_eval_url)
               .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        expect(stub).to have_been_requested
        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'keeps flags in memory when on_flag_definitions_received raises' do
        provider.should_fetch_return_value = true
        provider.on_received_error = RuntimeError.new('Redis write error')

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider)

        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'continues shutdown when provider shutdown raises' do
        provider.should_fetch_return_value = true
        provider.shutdown_error = RuntimeError.new('Redis error')

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider)

        expect { client.shutdown }.not_to raise_error
        expect(provider.shutdown_call_count).to eq(1)
      end
    end

    describe 'shutdown lifecycle' do
      it 'calls provider shutdown via client shutdown' do
        provider.should_fetch_return_value = true

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider)

        client.shutdown
        expect(provider.shutdown_call_count).to eq(1)
      end
    end

    describe 'backward compatibility' do
      it 'works without a cache provider' do
        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)

        client = Client.new(
          api_key: API_KEY,
          personal_api_key: API_KEY,
          test_mode: true
        )

        poller = client.instance_variable_get(:@feature_flags_poller)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end
    end

    describe 'data integrity' do
      it 'evaluates flags loaded from cache' do
        provider.should_fetch_return_value = false
        provider.stored_data = sample_flags_data

        stub = stub_request(:get, local_eval_url)
               .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        expect(stub).not_to have_been_requested

        result = client.get_feature_flag(
          'test-flag', 'some-user',
          person_properties: { 'region' => 'USA' },
          only_evaluate_locally: true
        )
        expect(result).to eq(true)

        result = client.get_feature_flag(
          'disabled-flag', 'some-user',
          only_evaluate_locally: true
        )
        expect(result).to eq(false)
      end

      it 'handles string-keyed cache data correctly' do
        provider.should_fetch_return_value = false
        provider.stored_data = sample_flags_data

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        poller = get_poller(client)
        flags_by_key = poller.instance_variable_get(:@feature_flags_by_key)
        expect(flags_by_key).to have_key('test-flag')
        expect(flags_by_key['test-flag'][:active]).to eq(true)
      end

      it 'loads group_type_mapping from cache' do
        provider.should_fetch_return_value = false
        provider.stored_data = sample_flags_data

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        poller = get_poller(client)
        mapping = poller.instance_variable_get(:@group_type_mapping)
        expect(mapping[:'0']).to eq('company')
        expect(mapping[:'1']).to eq('project')
      end

      it 'loads cohorts from cache' do
        provider.should_fetch_return_value = false
        provider.stored_data = sample_flags_data

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        poller = get_poller(client)
        cohorts = poller.instance_variable_get(:@cohorts)
        expect(cohorts[:'1']).to be_a(Hash)
        expect(cohorts[:'1'][:type]).to eq('AND')
      end

      it 'persists the minimal_flag_called_events gate to the cache provider' do
        provider.should_fetch_return_value = true

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.merge('minimal_flag_called_events' => true).to_json)
        create_client_with_cache(provider: provider, stub_api: false)

        expect(provider.stored_data[:minimal_flag_called_events]).to eq(true)
      end

      it 'applies the minimal_flag_called_events gate from cached data' do
        provider.should_fetch_return_value = false
        provider.stored_data = sample_flags_data.merge('minimal_flag_called_events' => true)

        client = create_client_with_cache(provider: provider, stub_api: false)

        expect(get_poller(client).minimal_flag_called_events).to eq(true)
      end

      it 'updates cache when API returns new data' do
        provider.should_fetch_return_value = true

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)
        expect(provider.stored_data[:flags].first[:active]).to be(true)

        updated = Marshal.load(Marshal.dump(sample_flags_data))
        updated['flags'].first['active'] = false
        stub_request(:get, local_eval_url).to_return(status: 200, body: updated.to_json)
        client.reload_feature_flags

        expect(provider.on_received_call_count).to eq(2)
        expect(provider.stored_data[:flags].length).to eq(2)
        expect(provider.stored_data[:flags].first).to include(key: 'test-flag', active: false)
        expect(client.get_feature_flag('test-flag', 'user', only_evaluate_locally: true)).to be(false)
      end

      it 'roundtrip: data stored after API fetch can be loaded via JSON serialization' do
        provider.should_fetch_return_value = true

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: sample_flags_data.to_json)
        client1 = create_client_with_cache(provider: provider, stub_api: false)
        client1.shutdown

        # Simulate what a real cache (e.g., Redis with JSON serialization) would do:
        # JSON.parse(JSON.dump(data)) converts symbol keys back to strings
        serialized_data = JSON.parse(JSON.dump(provider.stored_data))

        # Create a second "instance" that reads from cache.
        # Stub the API with EMPTY flags so we can distinguish cache vs API results:
        # if cache works, 'test-flag' evaluates to true; if API is used, it returns nil.
        provider2 = MockCacheProvider.new
        provider2.should_fetch_return_value = false
        provider2.stored_data = serialized_data

        stub_request(:get, local_eval_url)
          .to_return(status: 200, body: { 'flags' => [], 'group_type_mapping' => {}, 'cohorts' => {} }.to_json)
        client2 = create_client_with_cache(provider: provider2, stub_api: false)

        expect(provider2.get_call_count).to be >= 1

        result = client2.get_feature_flag(
          'test-flag', 'some-user',
          person_properties: { 'region' => 'USA' },
          only_evaluate_locally: true
        )
        expect(result).to eq(true)
      end

      it 'picks up updated cache data on subsequent poll cycles' do
        provider.should_fetch_return_value = false
        provider.stored_data = sample_flags_data

        stub = stub_request(:get, local_eval_url)
               .to_return(status: 200, body: sample_flags_data.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)

        # Simulate leader updating cache with a new flag
        updated_flags = sample_flags_data['flags'] + [
          { 'id' => 3, 'key' => 'new-flag', 'active' => true, 'filters' => {} }
        ]
        provider.stored_data = sample_flags_data.merge('flags' => updated_flags)

        poller.send(:_load_feature_flags)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(3)
        expect(stub).not_to have_been_requested
      end
    end
  end
end
