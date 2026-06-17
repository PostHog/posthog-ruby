# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe SendWorker do
    around do |example|
      PostHog::Transport.stub = true
      example.call
      PostHog::Transport.stub = false
    end

    describe '#init' do
      it 'accepts string keys' do
        queue = Queue.new
        worker = described_class.new(queue, 'secret', 'batch_size' => 100, 'flush_interval_seconds' => 2)
        batch = worker.instance_variable_get(:@batch)
        expect(batch.instance_variable_get(:@max_message_count)).to eq(100)
        expect(worker.instance_variable_get(:@flush_interval_seconds)).to eq(2.0)
      end

      it 'defaults flush_interval_seconds to 5 seconds' do
        queue = Queue.new
        worker = described_class.new(queue, 'secret')

        expect(worker.instance_variable_get(:@flush_interval_seconds)).to eq(5.0)
      end
    end

    describe '#run' do
      before :all do
        PostHog::Defaults::Request::BACKOFF = 0.1
      end

      after :all do
        PostHog::Defaults::Request.send(:remove_const, :BACKOFF)
        PostHog::Defaults::Request::BACKOFF = 30.0
      end

      it 'does not error if the request fails' do
        expect do
          allow_any_instance_of(PostHog::Transport).to(
            receive(:send).and_return(PostHog::Response.new(-1, 'Unknown error'))
          )

          queue = Queue.new
          queue << {}
          worker = described_class.new(queue, 'secret', flush_interval_seconds: 0)
          worker.run

          expect(queue).to be_empty
        end.to_not raise_error
      end

      it 'executes the error handler if the request is invalid' do
        allow_any_instance_of(PostHog::Transport).to(
          receive(:send).and_return(PostHog::Response.new(400, 'Some error'))
        )

        status = error = nil
        on_error =
          proc do |yielded_status, yielded_error|
            sleep 0.2 # Make this take longer than thread spin-up (below)
            status = yielded_status
            error = yielded_error
          end

        queue = Queue.new
        queue << {}
        worker = described_class.new(queue, 'secret', on_error: on_error, flush_interval_seconds: 0)

        # This is to ensure that Client#flush doesn't finish before calling
        # the error handler.
        Thread.new { worker.run }
        sleep 0.1 # First give thread time to spin-up.
        sleep 0.01 while worker.is_requesting?

        expect(queue).to be_empty
        expect(status).to eq(400)
        expect(error).to eq('Some error')
      end

      it 'clears the in-flight batch if the error handler raises' do
        queue = Queue.new
        queue << {}
        worker = described_class.new(queue, 'secret', on_error: proc { raise 'handler failed' })
        transport = instance_double(
          PostHog::Transport,
          send: PostHog::Response.new(400, 'Some error'),
          shutdown: nil
        )
        worker.instance_variable_set(:@transport, transport)

        expect { worker.run }.to_not raise_error
        expect(queue).to be_empty
        expect(worker.is_requesting?).to eq(false)
      end

      it 'does not call on_error if the request is good' do
        on_error = proc { |status, error| puts "#{status}, #{error}" }

        expect(on_error).to_not receive(:call)

        queue = Queue.new
        queue << Requested::CAPTURE
        worker = described_class.new(queue, 'testsecret', on_error: on_error, flush_interval_seconds: 0)
        worker.run

        expect(queue).to be_empty
      end

      it 'calls on_error for bad json' do
        bad_obj = Object.new
        def bad_obj.to_json(*_args)
          raise "can't serialize to json"
        end

        on_error = proc {}
        expect(on_error).to receive(:call).once.with(-1, /serialize to json/)

        good_message = Requested::CAPTURE
        bad_message = Requested::CAPTURE.merge({ 'bad_obj' => bad_obj })

        queue = Queue.new
        queue << good_message
        queue << bad_message

        worker = described_class.new(queue, 'testsecret', on_error: on_error, flush_interval_seconds: 0)
        worker.run
        expect(queue).to be_empty
      end

      it 'waits for flush_interval_seconds before sending a partial batch' do
        sends = []
        allow_any_instance_of(PostHog::Transport).to receive(:send) do |_transport, _api_key, batch|
          sends << batch.length
          PostHog::Response.new(200, 'Success')
        end

        queue = Queue.new
        queue << Requested::CAPTURE
        worker = described_class.new(queue, 'testsecret', batch_size: 10, flush_interval_seconds: 0.05)

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        worker.run
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        expect(sends).to eq([1])
        expect(elapsed).to be >= 0.05
      end

      it 'sends immediately when the batch size is reached' do
        sends = []
        allow_any_instance_of(PostHog::Transport).to receive(:send) do |_transport, _api_key, batch|
          sends << batch.length
          PostHog::Response.new(200, 'Success')
        end

        queue = Queue.new
        queue << Requested::CAPTURE
        queue << Requested::IDENTIFY
        worker = described_class.new(queue, 'testsecret', batch_size: 2, flush_interval_seconds: 60)

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        worker.run
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        expect(sends).to eq([2])
        expect(elapsed).to be < 1
      end

      it 'wakes and sends messages enqueued while waiting' do
        sent_batches = []
        allow_any_instance_of(PostHog::Transport).to receive(:send) do |_transport, _api_key, batch|
          sent_batches << JSON.parse(batch.to_json).map { |message| message['event'] }
          PostHog::Response.new(200, 'Success')
        end

        queue = Queue.new
        queue << Requested::CAPTURE
        worker = described_class.new(queue, 'testsecret', batch_size: 2, flush_interval_seconds: 60)

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        worker_thread = Thread.new { worker.run }
        eventually { expect(worker.is_requesting?).to eq(true) }

        queue << Requested::CAPTURE.merge(event: 'Second event')
        worker.notify

        expect(worker_thread.join(1)).to eq(worker_thread)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        expect(sent_batches).to eq([[Requested::CAPTURE[:event], 'Second event']])
        expect(elapsed).to be < 1
      end

      it 'flushes immediately when requested' do
        sends = []
        allow_any_instance_of(PostHog::Transport).to receive(:send) do |_transport, _api_key, batch|
          sends << batch.length
          PostHog::Response.new(200, 'Success')
        end

        queue = Queue.new
        queue << Requested::CAPTURE
        worker = described_class.new(queue, 'testsecret', batch_size: 10, flush_interval_seconds: 60)

        worker_thread = Thread.new { worker.run }
        eventually { expect(worker.is_requesting?).to eq(true) }
        worker.request_flush

        expect(worker_thread.join(1)).to eq(worker_thread)
        expect(sends).to eq([1])
      end
    end

    describe '#is_requesting?' do
      it 'does not return true if there isn\'t a current batch' do
        queue = Queue.new
        worker = described_class.new(queue, 'testsecret')

        expect(worker.is_requesting?).to eq(false)
      end

      it 'returns true if there is a current batch' do
        allow_any_instance_of(PostHog::Transport).to receive(:send) do
          sleep(0.2)
          PostHog::Response.new(200, 'Success')
        end

        queue = Queue.new
        queue << Requested::CAPTURE
        worker = described_class.new(queue, 'testsecret', flush_interval_seconds: 0)

        worker_thread = Thread.new { worker.run }
        eventually { expect(worker.is_requesting?).to eq(true) }

        worker_thread.join
        expect(worker.is_requesting?).to eq(false)
      end
    end
  end
end
