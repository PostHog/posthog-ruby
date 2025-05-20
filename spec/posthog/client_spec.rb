require 'spec_helper'

class PostHog
  flags_endpoint = 'https://app.posthog.com/flags/?v=2'

  RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil

  describe Client do
    let(:client) { Client.new(api_key: API_KEY, test_mode: true) }
    let(:logger) { instance_double(Logger) }

    before do
      allow(PostHog::Logging).to receive(:logger).and_return(logger)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:info)
      allow(logger).to receive(:debug)
    end

    describe '#initialize' do
      it 'errors if no api_key is supplied' do
        expect { Client.new }.to raise_error(ArgumentError)
      end

      it 'does not error if a api_key is supplied' do
        expect { Client.new api_key: API_KEY }.to_not raise_error
      end

      it 'does not error if a api_key is supplied as a string' do
        expect { Client.new 'api_key' => API_KEY }.to_not raise_error
      end

      it 'handles skip_ssl_verification' do
        expect(PostHog::Transport).to receive(:new).with({ api_host: 'https://app.posthog.com',
                                                           skip_ssl_verification: true })
        expect { Client.new api_key: API_KEY, skip_ssl_verification: true }.to_not raise_error
      end
    end

    describe '#capture' do
      it 'errors without an event' do
        expect { client.capture(distinct_id: 'user') }.to raise_error(
          ArgumentError
        )
      end

      it 'errors without a distinct_id' do
        expect { client.capture(event: 'Event') }.to raise_error(ArgumentError)
      end

      it 'errors if properties is not a hash' do
        expect do
          client.capture(
            { distinct_id: 'user', event: 'Event', properties: [1, 2, 3] }
          )
        end.to raise_error(ArgumentError)
      end

      it 'uses the timestamp given' do
        time = Time.parse('1990-07-16 13:30:00.123 UTC')

        client.capture(
          {
            event: 'testing the timestamp',
            distinct_id: 'joe',
            timestamp: time
          }
        )

        expect(Time.parse(client.dequeue_last_message[:timestamp])).to eq(time)
      end

      it 'does not error with the required options' do
        expect do
          client.capture Queued::CAPTURE
          client.dequeue_last_message
        end.to_not raise_error
      end

      it 'does not error when given string keys' do
        expect do
          client.capture Utils.stringify_keys(Queued::CAPTURE)
          client.dequeue_last_message
        end.to_not raise_error
      end

      it 'converts time and date properties into iso8601 format' do
        client.capture(
          {
            distinct_id: 'user',
            event: 'Event',
            properties: {
              time: Time.utc(2013),
              time_with_zone: Time.zone.parse('2013-01-01'),
              date_time: DateTime.new(2013, 1, 1),
              date: Date.new(2013, 1, 1),
              nottime: 'x'
            }
          }
        )

        properties = client.dequeue_last_message[:properties]

        date_time = DateTime.new(2013, 1, 1)
        expect(Time.iso8601(properties[:time])).to eq(date_time)
        expect(Time.iso8601(properties[:time_with_zone])).to eq(date_time)
        expect(Time.iso8601(properties[:date_time])).to eq(date_time)

        date = Date.new(2013, 1, 1)
        expect(Date.iso8601(properties[:date])).to eq(date)

        expect(properties[:nottime]).to eq('x')
      end

      it 'captures feature flags' do
        flags_response = { featureFlags: { :'beta-feature' => 'random-variant' } }
        # Mock response for flags
        api_feature_flag_res = {
          flags: [
            {
              id: 1,
              name: '',
              key: 'beta-feature',
              active: true,
              is_simple_flag: false,
              rollout_percentage: 100
            }
          ]
        }

        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)
        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: flags_response.to_json)
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        c.capture(
          {
            distinct_id: 'distinct_id',
            event: 'ruby test event',
            send_feature_flags: true
          }
        )
        properties = c.dequeue_last_message[:properties]
        expect(properties['$feature/beta-feature']).to eq(false)
        expect(properties['$active_feature_flags']).to eq([])
      end

      it 'captures feature flags with fallback to server when needed' do
        flags_response = { 'featureFlags' => { 'beta-feature' => 'random-variant', 'alpha-feature' => true,
                                               'off-feature' => false } }
        # Mock response for /flags
        api_feature_flag_res = {
          'flags' => [
            {
              'id' => 1,
              'name' => '',
              'key' => 'beta-feature',
              'active' => true,
              'is_simple_flag' => false,
              'rollout_percentage' => 100,
              'filters' => {
                'groups' => [
                  {
                    'properties' => [{ 'key' => 'regionXXX', 'value' => 'USA', 'type' => 'person' }],
                    'rollout_percentage' => 100
                  }
                ]
              }
            }
          ]
        }

        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)
        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: flags_response.to_json)
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        c.capture(
          {
            distinct_id: 'distinct_id',
            event: 'ruby test event',
            send_feature_flags: true
          }
        )
        properties = c.dequeue_last_message[:properties]
        expect(properties['$feature/beta-feature']).to eq('random-variant')
        expect(properties['$feature/alpha-feature']).to eq(true)
        expect(properties['$feature/off-feature']).to eq(false)
        expect(properties['$active_feature_flags']).to eq(%w[beta-feature alpha-feature])
      end

      it 'captures active feature flags only' do
        flags_response = { 'featureFlags' => { 'beta-feature' => 'random-variant', 'alpha-feature' => true,
                                               'off-feature' => false } }
        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret'
        ).to_return(status: 200, body: {}.to_json)
        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: flags_response.to_json)
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        c.capture(
          {
            distinct_id: 'distinct_id',
            event: 'ruby test event',
            send_feature_flags: true
          }
        )
        properties = c.dequeue_last_message[:properties]
        expect(properties['$feature/beta-feature']).to eq('random-variant')
        expect(properties['$feature/alpha-feature']).to eq(true)
        expect(properties['$active_feature_flags']).to eq(%w[beta-feature alpha-feature])
      end

      it 'captures feature flags when no personal API key is present' do
        flags_response = { 'featureFlags' => { 'beta-feature' => 'random-variant' } }
        # Mock response for flags

        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret'
        ).to_return(status: 401, body: { 'error' => 'not authorized' }.to_json)
        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: flags_response.to_json)
        c = Client.new(api_key: API_KEY, test_mode: true)

        c.capture(
          {
            distinct_id: 'distinct_id',
            event: 'ruby test event',
            send_feature_flags: true
          }
        )
        properties = c.dequeue_last_message[:properties]
        expect(properties['$feature/beta-feature']).to eq('random-variant')
        expect(properties['$active_feature_flags']).to eq(['beta-feature'])

        assert_not_requested :get, 'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret'
      end

      it 'manages memory well when sending feature flags' do
        api_feature_flag_res = {
          flags: [
            {
              id: 1,
              name: 'Beta Feature',
              key: 'beta-feature',
              active: true,
              filters: {
                groups: [
                  {
                    properties: [],
                    rollout_percentage: 100
                  }
                ]
              }
            }
          ]
        }
        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)

        stub_const('PostHog::Defaults::MAX_HASH_SIZE', 10)
        stub_const('PostHog::VERSION', '1.2.4')

        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        expect(c.instance_variable_get(:@distinct_id_has_sent_flag_calls).length).to eq(0)

        1000.times do |i|
          distinct_id = "some-distinct-id#{i}"
          c.get_feature_flag('beta-feature', distinct_id)

          captured_message = c.dequeue_last_message
          expect(captured_message[:distinct_id]).to eq(distinct_id)
          expect(captured_message[:event]).to eq('$feature_flag_called')
          expect(captured_message[:properties]).to eq(
            '$feature_flag' => 'beta-feature',
            '$feature_flag_response' => true,
            '$lib' => 'posthog-ruby',
            '$lib_version' => '1.2.4',
            '$groups' => {},
            'locally_evaluated' => true
          )
          expect(c.instance_variable_get(:@distinct_id_has_sent_flag_calls).length <= 10).to eq(true)
        end
      end

      it '$feature_flag_called is called appropriately when querying flags' do
        api_feature_flag_res = {
          'flags' => [
            {
              'id' => 1,
              'name' => 'Beta Feature',
              'key' => 'beta-feature',
              'active' => true,
              'filters' => {
                'groups' => [
                  {
                    'properties' => [{ 'key' => 'region', 'value' => 'USA' }],
                    'rollout_percentage' => 100
                  }
                ]
              }
            },
            {
              'id' => 2,
              'name' => 'Beta Feature',
              'key' => 'decide-flag',
              'active' => true,
              'filters' => {
                'groups' => [
                  {
                    'properties' => [{ 'key' => 'region?????', 'value' => 'USA' }],
                    'rollout_percentage' => 100
                  }
                ]
              }
            }
          ]
        }

        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: { 'featureFlags' => { 'decide-flag' => 'decide-value' } }.to_json)

        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)

        stub_const('PostHog::Defaults::MAX_HASH_SIZE', 10)
        stub_const('PostHog::VERSION', '1.2.4')

        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
        allow(c).to receive(:capture)
        expect(c).to receive(:capture).with({
                                              distinct_id: 'some-distinct-id',
                                              event: '$feature_flag_called',
                                              properties: {
                                                '$feature_flag' => 'beta-feature',
                                                '$feature_flag_response' => true,
                                                'locally_evaluated' => true
                                              },
                                              groups: {}
                                            }).exactly(1).times
        expect(c.get_feature_flag('beta-feature', 'some-distinct-id',
                                  person_properties: { 'region' => 'USA', 'name' => 'Aloha' })).to eq(true)

        # reset capture mock
        RSpec::Mocks.space.proxy_for(c).reset
        allow(c).to receive(:capture)
        # called again for same user, shouldn't call capture again
        expect(c).not_to receive(:capture)
        expect(c.get_feature_flag('beta-feature', 'some-distinct-id',
                                  person_properties: { 'region' => 'USA', 'name' => 'Aloha' })).to eq(true)

        RSpec::Mocks.space.proxy_for(c).reset
        allow(c).to receive(:capture)
        # called for different user, should call capture again
        expect(c).to receive(:capture).with({
                                              distinct_id: 'some-distinct-id2',
                                              event: '$feature_flag_called',
                                              properties: {
                                                '$feature_flag' => 'beta-feature',
                                                '$feature_flag_response' => true,
                                                'locally_evaluated' => true
                                              },
                                              groups: {}
                                            }).exactly(1).times
        expect(c.get_feature_flag('beta-feature', 'some-distinct-id2',
                                  person_properties: { 'region' => 'USA', 'name' => 'Aloha' })).to eq(true)

        # called for different user, but send configuration is false, so should NOT call capture again
        expect(c.get_feature_flag(
                 'beta-feature',
                 'some-distinct-id23',
                 person_properties: { 'region' => 'USA', 'name' => 'Aloha' },
                 send_feature_flag_events: false
               )).to eq(true)

        # called for different flag, falls back to decide, should call capture again
        expect(c).to receive(:capture).with({
                                              distinct_id: 'some-distinct-id2345',
                                              event: '$feature_flag_called',
                                              properties: {
                                                '$feature_flag' => 'decide-flag',
                                                '$feature_flag_response' => 'decide-value',
                                                'locally_evaluated' => false
                                              },
                                              groups: { organization: 'org1' }
                                            }).exactly(1).times
        expect(c.get_feature_flag(
                 'decide-flag',
                 'some-distinct-id2345',
                 person_properties: { 'region' => 'USA', 'name' => 'Aloha' },
                 groups: { organization: 'org1' }
               )).to eq('decide-value')

        expect(c).not_to receive(:capture)
        expect(c.is_feature_enabled(
                 'decide-flag',
                 'some-distinct-id2345',
                 person_properties: { 'region' => 'USA', 'name' => 'Aloha' },
                 groups: { 'organization' => 'org1' }
               )).to eq(true)
      end

      it 'captures groups' do
        client.capture(
          {
            distinct_id: 'distinct_id',
            event: 'test_event',
            groups: {
              'company' => 'id:5',
              'instance' => 'app.posthog.com'
            }
          }
        )
        properties = client.dequeue_last_message[:properties]
        expect(properties['$groups']).to eq({ 'company' => 'id:5', 'instance' => 'app.posthog.com' })
      end

      it 'captures uuid when provided' do
        client.capture(
          {
            distinct_id: 'distinct_id',
            event: 'test_event',
            uuid: '123e4567-e89b-12d3-a456-426614174000'
          }
        )
        last_message = client.dequeue_last_message
        expect(last_message['uuid']).to eq('123e4567-e89b-12d3-a456-426614174000')
      end

      it 'does not require a uuid be provided - ingestion will generate when absent' do
        client.capture(
          {
            distinct_id: 'distinct_id',
            event: 'test_event'
          }
        )
        properties = client.dequeue_last_message[:properties]
        # ingestion will add a UUID if one is not provided
        expect(properties['uuid']).to be_nil
      end

      it 'does not use invalid uuid' do
        client.capture(
          {
            distinct_id: 'distinct_id',
            event: 'test_event',
            uuid: 'i am obviously not a uuid'
          }
        )
        properties = client.dequeue_last_message[:properties]
        expect(properties['uuid']).to be_nil
        expect(logger).to have_received(:warn).with(
          'UUID is not valid: i am obviously not a uuid. Ignoring it.'
        )
      end
    end

    describe '#identify' do
      it 'errors without any user id' do
        expect { client.identify({}) }.to raise_error(ArgumentError)
      end

      it 'does not error with the required options' do
        expect do
          client.identify Queued::IDENTIFY
          client.dequeue_last_message
        end.to_not raise_error
      end

      it 'does not error with the required options as strings' do
        expect do
          client.identify Utils.stringify_keys(Queued::IDENTIFY)
          client.dequeue_last_message
        end.to_not raise_error
      end

      it 'converts time and date properties into iso8601 format' do
        client.identify(
          {
            distinct_id: 'user',
            properties: {
              time: Time.utc(2013),
              time_with_zone: Time.zone.parse('2013-01-01'),
              date_time: DateTime.new(2013, 1, 1),
              date: Date.new(2013, 1, 1),
              nottime: 'x'
            }
          }
        )

        properties = client.dequeue_last_message[:$set] # NB!!!!!

        date_time = DateTime.new(2013, 1, 1)
        expect(Time.iso8601(properties[:time])).to eq(date_time)
        expect(Time.iso8601(properties[:time_with_zone])).to eq(date_time)
        expect(Time.iso8601(properties[:date_time])).to eq(date_time)

        date = Date.new(2013, 1, 1)
        expect(Date.iso8601(properties[:date])).to eq(date)

        expect(properties[:nottime]).to eq('x')
      end
    end

    describe '#group_identify' do
      it 'errors without group key or group type' do
        expect { client.group_identify({}) }.to raise_error(ArgumentError)
      end

      it 'identifies group with unique id' do
        client.group_identify(
          {
            group_type: 'organization',
            group_key: 'id:5',
            properties: {
              trait: 'value'
            }
          }
        )
        msg = client.dequeue_last_message

        expect(msg[:distinct_id]).to eq('$organization_id:5')
        expect(msg[:event]).to eq('$groupidentify')
        expect(msg[:properties][:$group_type]).to eq('organization')
        expect(msg[:properties][:$group_set][:trait]).to eq('value')
      end

      it 'allows passing optional distinct_id to identify group' do
        client.group_identify(
          {
            group_type: 'organization',
            group_key: 'id:5',
            properties: {
              trait: 'value'
            },
            distinct_id: '123'
          }
        )
        msg = client.dequeue_last_message

        expect(msg[:distinct_id]).to eq('123')
        expect(msg[:event]).to eq('$groupidentify')
        expect(msg[:properties][:$group_type]).to eq('organization')
        expect(msg[:properties][:$group_set][:trait]).to eq('value')
      end
    end

    describe '#alias' do
      it 'errors without from' do
        expect { client.alias distinct_id: 1234 }.to raise_error(ArgumentError)
      end

      it 'errors without to' do
        expect { client.alias alias: 1234 }.to raise_error(ArgumentError)
      end

      it 'does not error with the required options' do
        expect { client.alias ALIAS.dup }.to_not raise_error
      end

      it 'does not error with the required options as strings' do
        expect { client.alias Utils.stringify_keys(ALIAS) }.to_not raise_error
      end

      it 'sets distinct_id property' do
        client.alias(
          {
            distinct_id: 'old_user',
            alias: 'new_user'
          }
        )

        message = client.dequeue_last_message
        expect(message).to include(
          {
            type: 'alias',
            distinct_id: 'old_user',
            event: '$create_alias'
          }
        )
        expect(message[:properties]).to include(
          distinct_id: 'old_user',
          alias: 'new_user'
        )
      end
    end

    describe '#flush' do
      before do
        clients_queue = client.instance_variable_get(:@queue)
        empyting_worker = Class.new(NoopWorker) do # A worker that empties jobs
          def run
            @queue.clear
          end
        end.new(clients_queue)
        client.instance_variable_set(:@worker, empyting_worker)
      end

      it 'waits for the queue to finish on a flush' do
        client.identify Queued::IDENTIFY
        client.capture Queued::CAPTURE
        client.flush

        expect(client.queued_messages).to eq(0)
      end

      unless defined?(JRUBY_VERSION)
        it 'completes when the process forks' do
          client.identify Queued::IDENTIFY

          Process.fork do
            client.capture Queued::CAPTURE
            client.flush
            expect(client.queued_messages).to eq(0)
          end

          Process.wait
        end
      end
    end

    describe 'feature flags' do
      it 'evaluates flags correctly' do
        api_feature_flag_res = {
          flags: [
            {
              id: 719,
              name: '',
              key: 'simple_flag',
              active: true,
              is_simple_flag: true,
              rollout_percentage: nil,
              filters: {
                groups: [
                  { properties: [], rollout_percentage: nil }
                ]
              }
            },
            {
              id: 720,
              name: '',
              key: 'disabled_flag',
              active: false,
              is_simple_flag: true,
              filters: {
                groups: [
                  { properties: [], rollout_percentage: nil }
                ]
              }
            },
            {
              id: 721,
              name: '',
              key: 'complex_flag',
              active: true,
              is_simple_flag: false,
              rollout_percentage: nil,
              filters: {
                groups: [
                  { properties: [], rollout_percentage: nil }
                ]
              }
            }
          ]
        }

        flags_response = { featureFlags: { complex_flag: true } }

        # Mock response for api/feature_flag
        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)

        # Mock response for `/flags`
        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: flags_response.to_json)

        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        expect(c.is_feature_enabled('simple_flag', 'some id')).to eq(true)
        expect(c.is_feature_enabled('disabled_flag', 'some id')).to eq(false)
        expect(c.is_feature_enabled('complex_flag', 'some id')).to eq(true)
      end

      it 'doesnt fail without a personal api key' do
        client = Client.new(api_key: API_KEY, test_mode: true)

        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: { 'featureFlags' => { 'some_key' => true } }.to_json)

        expect(client.is_feature_enabled('some_key', 'some id')).to eq(true)
      end

      it 'default properties get added properly' do
        client = Client.new(api_key: API_KEY, test_mode: true)

        stub_request(:post, flags_endpoint)
          .to_return(status: 200, body: {
            'featureFlags' => { 'beta-feature' => 'random-variant', 'alpha-feature' => true,
                                'off-feature' => false }, 'featureFlagPayloads' => {}
          }.to_json)

        client.get_feature_flag(
          'random_key',
          'some_id',
          groups: { 'company' => 'id:5', 'instance' => 'app.posthog.com' },
          person_properties: { 'x1' => 'y1' },
          group_properties: { 'company' => { 'x' => 'y' } }
        )
        assert_requested :post, flags_endpoint, times: 1
        expect(WebMock).to have_requested(:post, flags_endpoint).with(
          body: {
            'distinct_id' => 'some_id',
            'groups' => { 'company' => 'id:5', 'instance' => 'app.posthog.com' },
            'group_properties' => {
              'company' => { '$group_key' => 'id:5', 'x' => 'y' },
              'instance' => { '$group_key' => 'app.posthog.com' }
            },
            'person_properties' => { 'distinct_id' => 'some_id', 'x1' => 'y1' }, 'token' => 'testsecret'
          }
        )

        WebMock.reset_executed_requests!

        client.get_feature_flag(
          'random_key',
          'some_id',
          groups: { 'company' => 'id:5', 'instance' => 'app.posthog.com' },
          person_properties: { 'distinct_id' => 'override' },
          group_properties: { 'company' => { '$group_key' => 'group_override' } }
        )

        assert_requested :post, flags_endpoint, times: 1
        expect(WebMock).to have_requested(:post, flags_endpoint).with(
          body: {
            'distinct_id' => 'some_id',
            'groups' => { 'company' => 'id:5', 'instance' => 'app.posthog.com' },
            'group_properties' => {
              'company' => { '$group_key' => 'group_override' },
              'instance' => { '$group_key' => 'app.posthog.com' }
            },
            'person_properties' => { 'distinct_id' => 'override' },
            'token' => 'testsecret'
          }
        )
        WebMock.reset_executed_requests!

        # test nones
        client.get_all_flags_and_payloads('some_id', groups: {}, person_properties: nil, group_properties: nil)
        assert_requested :post, flags_endpoint, times: 1
        expect(WebMock).to have_requested(:post, flags_endpoint).with(
          body: { 'distinct_id' => 'some_id', 'groups' => {}, 'group_properties' => {},
                  'person_properties' => { 'distinct_id' => 'some_id' }, 'token' => 'testsecret' }
        )
        WebMock.reset_executed_requests!

        client.get_all_flags('some_id', groups: { 'company' => 'id:5' }, person_properties: nil, group_properties: nil)
        assert_requested :post, flags_endpoint, times: 1
        expect(WebMock).to have_requested(:post, flags_endpoint).with(
          body: {
            'distinct_id' => 'some_id',
            'groups' => { 'company' => 'id:5' },
            'group_properties' => { 'company' => { '$group_key' => 'id:5' } },
            'person_properties' => { 'distinct_id' => 'some_id' },
            'token' => 'testsecret'
          }
        )
        WebMock.reset_executed_requests!

        client.get_feature_flag_payload(
          'random_key',
          'some_id',
          groups: {},
          person_properties: nil,
          group_properties: nil
        )
        assert_requested :post, flags_endpoint, times: 1
        expect(WebMock).to have_requested(:post, flags_endpoint).with(
          body: { 'distinct_id' => 'some_id', 'groups' => {}, 'group_properties' => {},
                  'person_properties' => { 'distinct_id' => 'some_id' }, 'token' => 'testsecret' }
        )
        WebMock.reset_executed_requests!

        client.is_feature_enabled('random_key', 'some_id', groups: {}, person_properties: nil, group_properties: nil)
        assert_requested :post, flags_endpoint, times: 1
        expect(WebMock).to have_requested(:post, flags_endpoint).with(
          body: { 'distinct_id' => 'some_id', 'groups' => {}, 'group_properties' => {},
                  'person_properties' => { 'distinct_id' => 'some_id' }, 'token' => 'testsecret' }
        )
        WebMock.reset_executed_requests!
      end
    end

    context 'common' do
      check_property = proc { |msg, k, v| msg[k] && msg[k] == v }

      let(:data) do
        { distinct_id: 1, alias: 3, message_id: 5, event: 'cockatoo' }
      end

      it 'returns false if queue is full' do
        client.instance_variable_set(:@max_queue_size, 1)

        %i[capture identify alias].each do |s|
          expect(client.send(s, data)).to eq(true)
          expect(client.send(s, data)).to eq(false) # Queue is full
          client.clear
        end
      end

      it 'converts message id to string' do
        %i[capture identify alias].each do |s|
          client.send(s, data)
          expect(check_property.call(client.dequeue_last_message, :messageId, '5')).to eq(true)
        end
      end
    end
  end
end
