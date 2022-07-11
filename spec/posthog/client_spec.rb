require 'spec_helper'

class PostHog
  describe Client do
    let(:client) { Client.new(api_key: API_KEY, test_mode: true) }

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
        expect(PostHog::Transport).to receive(:new).with({api_host: nil, skip_ssl_verification: true})
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
        expect {
          client.capture(
            { distinct_id: 'user', event: 'Event', properties: [1, 2, 3] }
          )
        }.to raise_error(ArgumentError)
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
        decide_res = {"featureFlags": {"beta-feature": "random-variant"}}
        # Mock response for decide
        api_feature_flag_res = {
          "results": [
            {
              "id": 1,
              "name": '',
              "key": 'beta-feature',
              "active": true,
              "is_simple_flag": false,
              "rollout_percentage": 100
            },]
          }

        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)
        stub_request(:post, 'https://app.posthog.com/decide/?v=2')
          .to_return(status: 200, body: decide_res.to_json)
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        c.capture(
          {
            distinct_id: "distinct_id",
            event: "ruby test event",
            send_feature_flags: true,
          }
        )
        properties = c.dequeue_last_message[:properties]
        expect(properties["$feature/beta-feature"]).to eq("random-variant")
        expect(properties["$active_feature_flags"]).to eq(["beta-feature"])
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

        properties = client.dequeue_last_message[:'$set'] # NB!!!!!

        date_time = DateTime.new(2013, 1, 1)
        expect(Time.iso8601(properties[:time])).to eq(date_time)
        expect(Time.iso8601(properties[:time_with_zone])).to eq(date_time)
        expect(Time.iso8601(properties[:date_time])).to eq(date_time)

        date = Date.new(2013, 1, 1)
        expect(Date.iso8601(properties[:date])).to eq(date)

        expect(properties[:nottime]).to eq('x')
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
        expect { client.alias ALIAS }.to_not raise_error
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
            event: "$create_alias"
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
      it 'decides flags correctly' do
        api_feature_flag_res = {
          "results": [
            {
              "id": 719,
              "name": '',
              "key": 'simple_flag',
              "active": true,
              "is_simple_flag": true,
              "rollout_percentage": nil
            },
            {
              "id": 720,
              "name": '',
              "key": 'disabled_flag',
              "active": false,
              "is_simple_flag": true,
              "rollout_percentage": nil
            },
            {
              "id": 721,
              "name": '',
              "key": 'complex_flag',
              "active": true,
              "is_simple_flag": false,
              "rollout_percentage": nil
            }
          ]
        }

        decide_res = { "featureFlags": {"complex_flag": true} }

        # Mock response for api/feature_flag
        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)

        # Mock response for decide
        stub_request(:post, 'https://app.posthog.com/decide/?v=2')
          .to_return(status: 200, body: decide_res.to_json)

        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        expect(c.is_feature_enabled('simple_flag', 'some id')).to eq(true)
        expect(c.is_feature_enabled('disabled_flag', 'some id')).to eq(false)
        expect(c.is_feature_enabled('complex_flag', 'some id')).to eq(true)
      end

      it 'decides multivariate flags correctly' do 
        decide_res = {"featureFlags": {"beta-feature": "variant-1"}}
        api_feature_flag_res = {
          "results": [
            {
              "id": 1,
              "name": '',
              "key": 'beta-feature',
              "active": true,
              "is_simple_flag": false,
              "rollout_percentage": 100
            },]
          }

        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)

        stub_request(:post, 'https://app.posthog.com/decide/?v=2')
          .to_return(status: 200, body: decide_res.to_json)
        
        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

        expect(c.is_feature_enabled("beta-feature", "distinct_id")).to eq(true)
      end

      it 'gets feature flag' do
        decide_res = {"featureFlags": {"beta-feature": "variant-1"}}
        api_feature_flag_res = {
          "results": [
            {
              "id": 1,
              "name": '',
              "key": 'beta-feature',
              "active": true,
              "is_simple_flag": false,
              "rollout_percentage": 100
            },]
          }

        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)

        stub_request(:post, 'https://app.posthog.com/decide/?v=2')
          .to_return(status: 200, body: decide_res.to_json)

        c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
        expect(c.get_feature_flag("beta-feature", "distinct_id")).to eq("variant-1")
      end

      it 'fails without a personal api key' do
        bad_client = Client.new(api_key: API_KEY, test_mode: true)
        allow(bad_client.logger).to receive(:error)
        expect(bad_client.logger).to receive(:error).with(
          'You need to specify a personal_api_key to use feature flags'
        )
        bad_client.is_feature_enabled('some_key', 'some id')
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
