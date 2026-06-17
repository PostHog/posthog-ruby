# frozen_string_literal: true

require 'posthog/defaults'
require 'posthog/message_batch'
require 'posthog/transport'
require 'posthog/utils'

module PostHog
  # Background worker that batches and sends queued events.
  #
  # @api private
  class SendWorker
    include PostHog::Utils
    include PostHog::Defaults
    include PostHog::Logging

    # public: Creates a new worker
    #
    # The worker continuously takes messages off the queue
    # and makes requests to the posthog.com api
    #
    # @param queue [Queue] Queue synchronized between client and worker.
    # @param api_key [String] Project API key.
    # @param options [Hash] Worker options.
    # @option options [Integer] :batch_size How many items to send in a batch.
    # @option options [Numeric] :flush_interval Maximum seconds to wait for a batch to fill before sending.
    # @option options [Proc] :on_error Callback invoked as `on_error.call(status, error)`.
    # @option options [String] :host PostHog API host URL.
    # @option options [Boolean] :skip_ssl_verification Disable SSL certificate verification.
    def initialize(queue, api_key, options = {})
      symbolize_keys! options
      @queue = queue
      @api_key = api_key
      @on_error = options[:on_error] || proc { |status, error| }
      batch_size = options[:batch_size] || Defaults::MessageBatch::MAX_SIZE
      flush_interval = options[:flush_interval] || Defaults::MessageBatch::FLUSH_INTERVAL
      @flush_interval = flush_interval.to_f
      @batch = MessageBatch.new(batch_size)
      @lock = Mutex.new
      @state_lock = Mutex.new
      @condition = ConditionVariable.new
      @flush_requested = false
      @shutdown_requested = false
      @transport = Transport.new api_host: options[:host], skip_ssl_verification: options[:skip_ssl_verification]
    end

    # Continuously runs the loop to check for new events.
    #
    # @return [void]
    def run
      until Thread.current[:should_exit] || shutdown_requested?
        if @queue.empty?
          clear_flush_request
          return
        end

        build_batch
        send_batch unless @batch.empty?
        @lock.synchronize { @batch.clear }
      end
    ensure
      @transport.shutdown
    end

    # Request the worker to send any pending events without waiting for the
    # configured flush interval. Used by Client#flush and shutdown paths.
    #
    # @return [void]
    def request_flush
      @state_lock.synchronize do
        @flush_requested = true
        @condition.broadcast
      end
    end

    # Wake the worker when producers enqueue new messages.
    #
    # @return [void]
    def notify
      @state_lock.synchronize { @condition.signal }
    end

    # @return [void]
    def shutdown
      @state_lock.synchronize do
        @shutdown_requested = true
        @flush_requested = true
        @condition.broadcast
      end
      @transport.shutdown
    end

    # public: Check whether we have outstanding requests.
    #
    # @return [Boolean] Whether the worker has outstanding requests.
    # TODO: Rename to `requesting?` in future version
    def is_requesting? # rubocop:disable Naming/PredicateName
      @lock.synchronize { !@batch.empty? }
    end

    private

    def build_batch
      deadline = monotonic_time + @flush_interval

      loop do
        @lock.synchronize do
          consume_message_from_queue! until @batch.full? || @queue.empty?
        end

        break if @batch.full? || @batch.empty? || flush_requested?

        remaining = deadline - monotonic_time
        break unless remaining.positive?

        wait_for_more_messages(remaining)
      end
    end

    def send_batch
      res = @transport.send @api_key, @batch
      @on_error.call(res.status, res.error) unless res.status == 200
    end

    def consume_message_from_queue!
      @batch << @queue.pop(true)
    rescue ThreadError
      # Queue was emptied by another thread between #empty? and #pop.
    rescue MessageBatch::JSONGenerationError => e
      @on_error.call(-1, e.to_s)
    end

    def wait_for_more_messages(timeout)
      @state_lock.synchronize do
        return if @flush_requested || @shutdown_requested || !@queue.empty?

        @condition.wait(@state_lock, timeout)
      end
    end

    def flush_requested?
      @state_lock.synchronize { @flush_requested }
    end

    def shutdown_requested?
      @state_lock.synchronize { @shutdown_requested }
    end

    def clear_flush_request
      @state_lock.synchronize { @flush_requested = false }
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
