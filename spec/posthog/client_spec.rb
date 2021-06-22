require 'spec_helper'

class PostHog
  describe Client do
    let(:client) do
      Client
        .new(api_key: API_KEY)
        .tap do |client|
          # Ensure that worker doesn't consume items from the queue
          client.instance_variable_set(:@worker, NoopWorker.new)
        end
    end
    let(:queue) { client.instance_variable_get :@queue }

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

        msg = queue.pop

        expect(Time.parse(msg[:timestamp])).to eq(time)
      end

      it 'does not error with the required options' do
        expect do
          client.capture Queued::CAPTURE
          queue.pop
        end.to_not raise_error
      end

      it 'does not error when given string keys' do
        expect do
          client.capture Utils.stringify_keys(Queued::CAPTURE)
          queue.pop
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

        message = queue.pop
        properties = message[:properties]

        date_time = DateTime.new(2013, 1, 1)
        expect(Time.iso8601(properties[:time])).to eq(date_time)
        expect(Time.iso8601(properties[:time_with_zone])).to eq(date_time)
        expect(Time.iso8601(properties[:date_time])).to eq(date_time)

        date = Date.new(2013, 1, 1)
        expect(Date.iso8601(properties[:date])).to eq(date)

        expect(properties[:nottime]).to eq('x')
      end
    end

    describe '#identify' do
      it 'errors without any user id' do
        expect { client.identify({}) }.to raise_error(ArgumentError)
      end

      it 'does not error with the required options' do
        expect do
          client.identify Queued::IDENTIFY
          queue.pop
        end.to_not raise_error
      end

      it 'does not error with the required options as strings' do
        expect do
          client.identify Utils.stringify_keys(Queued::IDENTIFY)
          queue.pop
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

        message = queue.pop
        properties = message[:'$set'] # NB!!!!!

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
    end

    describe '#flush' do
      let(:client_with_worker) do
        Client
          .new(api_key: API_KEY)
          .tap do |client|
            queue = client.instance_variable_get(:@queue)
            client.instance_variable_set(:@worker, DummyWorker.new(queue))
          end
      end

      it 'waits for the queue to finish on a flush' do
        client_with_worker.identify Queued::IDENTIFY
        client_with_worker.capture Queued::CAPTURE
        client_with_worker.flush

        expect(client_with_worker.queued_messages).to eq(0)
      end

      unless defined?(JRUBY_VERSION)
        it 'completes when the process forks' do
          client_with_worker.identify Queued::IDENTIFY

          Process.fork do
            client_with_worker.capture Queued::CAPTURE
            client_with_worker.flush
            expect(client_with_worker.queued_messages).to eq(0)
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

        decide_res = { "featureFlags": ['complex_flag'] }

        # Mock response for api/feature_flag
        stub_request(
          :get,
          'https://app.posthog.com/api/feature_flag/?token=testsecret'
        ).to_return(status: 200, body: api_feature_flag_res.to_json)

        # Mock response for decide
        stub_request(:post, 'https://app.posthog.com/decide/?token=testsecret')
          .to_return(status: 200, body: decide_res.to_json)

        c =
          Client
            .new(api_key: API_KEY, personal_api_key: API_KEY)
            .tap do |client|
              client.instance_variable_set(:@worker, NoopWorker.new)
            end

        expect(c.is_feature_enabled('simple_flag', 'some id')).to eq(true)
        expect(c.is_feature_enabled('disabled_flag', 'some id')).to eq(false)
        expect(c.is_feature_enabled('complex_flag', 'some id')).to eq(true)
      end

      it 'fails without a personal api key' do
        bad_client =
          Client
            .new(api_key: API_KEY)
            .tap do |client|
              client.instance_variable_set(:@worker, NoopWorker.new)
            end
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
          queue.pop(true)
        end
      end

      it 'converts message id to string' do
        %i[capture identify alias].each do |s|
          client.send(s, data)
          message = queue.pop(true)

          expect(check_property.call(message, :messageId, '5')).to eq(true)
        end
      end
    end
  end
end
