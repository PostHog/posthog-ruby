# frozen_string_literal: true

require 'spec_helper'

module PostHog
  LOCAL_EVAL_URL = 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'

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

  # Sample API response with string keys (simulating JSON deserialization from cache)
  SAMPLE_FLAGS_DATA_STRING_KEYS = {
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
  }.freeze

  # API response format (what webmock returns)
  API_FLAG_RESPONSE = {
    'flags' => SAMPLE_FLAGS_DATA_STRING_KEYS['flags'],
    'group_type_mapping' => SAMPLE_FLAGS_DATA_STRING_KEYS['group_type_mapping'],
    'cohorts' => SAMPLE_FLAGS_DATA_STRING_KEYS['cohorts']
  }.freeze

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

    def create_client_with_cache(provider:, stub_api: true)
      if stub_api
        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
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

    describe 'cache initialization' do
      it 'uses cached data when should_fetch? returns false and cache has data' do
        provider.should_fetch_return_value = false
        provider.stored_data = SAMPLE_FLAGS_DATA_STRING_KEYS

        # The initial load_feature_flags call should use cache, not API
        stub = stub_request(:get, LOCAL_EVAL_URL)
               .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        # API should not have been called (initial load uses cache)
        expect(stub).not_to have_been_requested

        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
        expect(provider.get_call_count).to be >= 1
      end

      it 'fetches from API when should_fetch? returns true' do
        provider.should_fetch_return_value = true

        stub = stub_request(:get, LOCAL_EVAL_URL)
               .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        expect(stub).to have_been_requested
        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'uses emergency fallback when cache is empty and no flags loaded' do
        provider.should_fetch_return_value = false
        provider.stored_data = nil # Cache empty

        stub = stub_request(:get, LOCAL_EVAL_URL)
               .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        # Should have fallen back to API
        expect(stub).to have_been_requested
        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'preserves existing flags when cache returns nil but flags already loaded' do
        provider.should_fetch_return_value = true

        stub = stub_request(:get, LOCAL_EVAL_URL)
               .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
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

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider)

        initial_count = provider.should_fetch_call_count

        poller = get_poller(client)
        poller.send(:_load_feature_flags)

        expect(provider.should_fetch_call_count).to eq(initial_count + 1)
      end

      it 'stores data in cache after API fetch' do
        provider.should_fetch_return_value = true

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        create_client_with_cache(provider: provider)

        expect(provider.on_received_call_count).to be >= 1
        expect(provider.stored_data).not_to be_nil
        expect(provider.stored_data[:flags].length).to eq(2)
        expect(provider.stored_data[:group_type_mapping]).to be_a(Hash)
        expect(provider.stored_data[:cohorts]).to be_a(Hash)
      end

      it 'does not call on_flag_definitions_received when cache is used' do
        provider.should_fetch_return_value = true

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
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
        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(
            { status: 200, body: API_FLAG_RESPONSE.to_json, headers: { 'ETag' => 'abc123' } },
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

        stub = stub_request(:get, LOCAL_EVAL_URL)
               .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        expect(stub).to have_been_requested
        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'falls back to API fetch when flag_definitions raises' do
        provider.should_fetch_return_value = false
        provider.get_error = RuntimeError.new('Redis timeout')

        stub = stub_request(:get, LOCAL_EVAL_URL)
               .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        expect(stub).to have_been_requested
        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'keeps flags in memory when on_flag_definitions_received raises' do
        provider.should_fetch_return_value = true
        provider.on_received_error = RuntimeError.new('Redis write error')

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider)

        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)
      end

      it 'continues shutdown when provider shutdown raises' do
        provider.should_fetch_return_value = true
        provider.shutdown_error = RuntimeError.new('Redis error')

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider)

        expect { client.shutdown }.not_to raise_error
        expect(provider.shutdown_call_count).to eq(1)
      end
    end

    describe 'shutdown lifecycle' do
      it 'calls provider shutdown via client shutdown' do
        provider.should_fetch_return_value = true

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider)

        client.shutdown
        expect(provider.shutdown_call_count).to eq(1)
      end
    end

    describe 'backward compatibility' do
      it 'works without a cache provider' do
        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)

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
        provider.stored_data = SAMPLE_FLAGS_DATA_STRING_KEYS

        stub = stub_request(:get, LOCAL_EVAL_URL)
               .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
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
        provider.stored_data = SAMPLE_FLAGS_DATA_STRING_KEYS

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        poller = get_poller(client)
        flags_by_key = poller.instance_variable_get(:@feature_flags_by_key)
        expect(flags_by_key).to have_key('test-flag')
        expect(flags_by_key['test-flag'][:active]).to eq(true)
      end

      it 'loads group_type_mapping from cache' do
        provider.should_fetch_return_value = false
        provider.stored_data = SAMPLE_FLAGS_DATA_STRING_KEYS

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        poller = get_poller(client)
        mapping = poller.instance_variable_get(:@group_type_mapping)
        expect(mapping[:'0']).to eq('company')
        expect(mapping[:'1']).to eq('project')
      end

      it 'loads cohorts from cache' do
        provider.should_fetch_return_value = false
        provider.stored_data = SAMPLE_FLAGS_DATA_STRING_KEYS

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        poller = get_poller(client)
        cohorts = poller.instance_variable_get(:@cohorts)
        expect(cohorts[:'1']).to be_a(Hash)
        expect(cohorts[:'1'][:type]).to eq('AND')
      end

      it 'updates cache when API returns new data' do
        provider.should_fetch_return_value = true

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        create_client_with_cache(provider: provider)

        expect(provider.stored_data).not_to be_nil
        expect(provider.stored_data[:flags].length).to eq(2)
        expect(provider.stored_data[:flags].first[:key]).to eq('test-flag')
      end

      it 'roundtrip: data stored after API fetch can be loaded via JSON serialization' do
        provider.should_fetch_return_value = true

        stub_request(:get, LOCAL_EVAL_URL)
          .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
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

        stub_request(:get, LOCAL_EVAL_URL)
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
        provider.stored_data = SAMPLE_FLAGS_DATA_STRING_KEYS

        stub = stub_request(:get, LOCAL_EVAL_URL)
               .to_return(status: 200, body: API_FLAG_RESPONSE.to_json)
        client = create_client_with_cache(provider: provider, stub_api: false)

        poller = get_poller(client)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(2)

        # Simulate leader updating cache with a new flag
        updated_flags = SAMPLE_FLAGS_DATA_STRING_KEYS['flags'] + [
          { 'id' => 3, 'key' => 'new-flag', 'active' => true, 'filters' => {} }
        ]
        provider.stored_data = SAMPLE_FLAGS_DATA_STRING_KEYS.merge('flags' => updated_flags)

        poller.send(:_load_feature_flags)
        expect(poller.instance_variable_get(:@feature_flags).length).to eq(3)
        expect(stub).not_to have_been_requested
      end
    end
  end
end
