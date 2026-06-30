# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe SendWorker do
    around do |example|
      PostHog::Transport.stub = true
      example.call
      PostHog::Transport.stub = false
    end

    def run_worker_until_idle(worker, queue)
      worker_thread = Thread.new { worker.run }
      eventually { expect(queue).to be_empty }
      worker.shutdown
      expect(worker_thread.join(1)).to eq(worker_thread)
      expect(worker.is_requesting?).to eq(false)
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

      [
        {
          description: 'passes max_retries: 0 to the transport as one total attempt',
          options: { max_retries: 0 },
          expected_options: { retries: 1 }
        },
        {
          description: 'passes max_retries to the transport as total attempts',
          options: { max_retries: 2 },
          expected_options: { retries: 3 }
        },
        {
          description: 'passes compress_request false to the transport',
          options: { compress_request: false },
          expected_options: { compress_request: false }
        },
        {
          description: 'passes compress_request nil to the transport by default',
          options: {},
          expected_options: { compress_request: nil }
        }
      ].each do |configuration|
        it configuration[:description] do
          queue = Queue.new
          worker = described_class.new(queue, 'secret', configuration[:options])
          transport_options = worker.instance_variable_get(:@transport_options)

          configuration.fetch(:expected_options, {}).each do |key, value|
            expect(transport_options[key]).to eq(value)
          end

          configuration.fetch(:absent_options, []).each do |key|
            expect(transport_options).not_to have_key(key)
          end
        end
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
          run_worker_until_idle(worker, queue)

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
        worker_thread = Thread.new { worker.run }
        sleep 0.1 # First give thread time to spin-up.
        sleep 0.01 while worker.is_requesting?
        worker.shutdown
        worker_thread.join(1)

        expect(queue).to be_empty
        expect(status).to eq(400)
        expect(error).to eq('Some error')
      end

      it 'clears the in-flight batch if the error handler raises' do
        queue = Queue.new
        queue << {}
        worker = described_class.new(
          queue,
          'secret',
          on_error: proc { raise 'handler failed' },
          flush_interval_seconds: 0
        )
        transport = instance_double(
          PostHog::Transport,
          send: PostHog::Response.new(400, 'Some error'),
          shutdown: nil
        )
        worker.instance_variable_set(:@transport, transport)

        worker_thread = Thread.new { worker.run }
        eventually do
          expect(queue).to be_empty
          expect(worker.is_requesting?).to eq(false)
        end
        worker.shutdown

        expect(worker_thread.join(1)).to eq(worker_thread)
        expect(queue).to be_empty
        expect(worker.is_requesting?).to eq(false)
      end

      it 'does not call on_error if the request is good' do
        on_error = proc { |status, error| puts "#{status}, #{error}" }

        expect(on_error).to_not receive(:call)

        queue = Queue.new
        queue << Requested::CAPTURE
        worker = described_class.new(queue, 'testsecret', on_error: on_error, flush_interval_seconds: 0)
        run_worker_until_idle(worker, queue)

        expect(queue).to be_empty
      end

      it 'calls on_error for bad json' do
        bad_message = Requested::CAPTURE.dup
        def bad_message.to_json(*_args)
          raise "can't serialize to json"
        end

        on_error = proc {}
        expect(on_error).to receive(:call).once.with(-1, /serialize to json/)

        queue = Queue.new
        queue << bad_message

        worker = described_class.new(queue, 'testsecret', on_error: on_error, flush_interval_seconds: 0)
        run_worker_until_idle(worker, queue)
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
        worker_thread = Thread.new { worker.run }
        eventually { expect(sends).to eq([1]) }
        worker.shutdown
        expect(worker_thread.join(1)).to eq(worker_thread)
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
        worker_thread = Thread.new { worker.run }
        eventually { expect(sends).to eq([2]) }
        worker.shutdown
        expect(worker_thread.join(1)).to eq(worker_thread)
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

        eventually { expect(sent_batches).to eq([[Requested::CAPTURE[:event], 'Second event']]) }
        worker.shutdown
        expect(worker_thread.join(1)).to eq(worker_thread)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        expect(sent_batches).to eq([[Requested::CAPTURE[:event], 'Second event']])
        expect(elapsed).to be < 1
      end

      it 'stays alive while idle and handles a later enqueue' do
        sends = []
        allow_any_instance_of(PostHog::Transport).to receive(:send) do |_transport, _api_key, batch|
          sends << batch.length
          PostHog::Response.new(200, 'Success')
        end

        queue = Queue.new
        worker = described_class.new(queue, 'testsecret', batch_size: 1, flush_interval_seconds: 60)
        worker_thread = Thread.new { worker.run }

        eventually { expect(worker_thread).to be_alive }
        queue << Requested::CAPTURE
        worker.notify

        eventually { expect(sends).to eq([1]) }
        worker.shutdown
        expect(worker_thread.join(1)).to eq(worker_thread)
      end

      it 'does not keep a stale flush request while idle' do
        sends = []
        allow_any_instance_of(PostHog::Transport).to receive(:send) do |_transport, _api_key, batch|
          sends << batch.length
          PostHog::Response.new(200, 'Success')
        end

        queue = Queue.new
        worker = described_class.new(queue, 'testsecret', batch_size: 10, flush_interval_seconds: 0.05)
        worker_thread = Thread.new { worker.run }
        eventually { expect(worker_thread).to be_alive }

        worker.request_flush
        sleep 0.01
        queue << Requested::CAPTURE
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        worker.notify

        eventually { expect(sends).to eq([1]) }
        worker.shutdown
        expect(worker_thread.join(1)).to eq(worker_thread)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        expect(elapsed).to be >= 0.05
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

        eventually { expect(sends).to eq([1]) }
        worker.shutdown
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

        eventually { expect(worker.is_requesting?).to eq(false) }
        worker.shutdown
        worker_thread.join
        expect(worker.is_requesting?).to eq(false)
      end
    end
  end
end
