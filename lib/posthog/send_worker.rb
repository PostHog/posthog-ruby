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
    # @option options [Proc] :on_error Callback invoked as `on_error.call(status, error)`.
    # @option options [String] :host PostHog API host URL.
    # @option options [Boolean] :skip_ssl_verification Disable SSL certificate verification.
    def initialize(queue, api_key, options = {})
      symbolize_keys! options
      @queue = queue
      @api_key = api_key
      @on_error = options[:on_error] || proc { |status, error| }
      batch_size = options[:batch_size] || Defaults::MessageBatch::MAX_SIZE
      @batch = MessageBatch.new(batch_size)
      @lock = Mutex.new
      @shutdown_mutex = Mutex.new
      @shutdown = false
      @transport = Transport.new api_host: options[:host], skip_ssl_verification: options[:skip_ssl_verification]
    end

    # Continuously runs the loop to check for new events.
    #
    # @return [void]
    def run
      until shutdown?
        return if @queue.empty?

        @lock.synchronize do
          consume_message_from_queue! until @batch.full? || @queue.empty?
        end

        begin
          unless @batch.empty?
            res = @transport.send @api_key, @batch
            handle_error(res.status, res.error) unless res.status == 200
          end
        ensure
          @lock.synchronize { @batch.clear }
        end
      end
    ensure
      # Worker threads exit when the queue is drained and are restarted for the
      # next burst of events. Close the persistent connection on each exit and
      # let Transport reconnect lazily when a future worker sends another batch.
      @transport.shutdown
    end

    # @return [void]
    def shutdown
      @shutdown_mutex.synchronize { @shutdown = true }
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

    def shutdown?
      @shutdown_mutex.synchronize { @shutdown }
    end

    def consume_message_from_queue!
      @batch << @queue.pop
    rescue MessageBatch::JSONGenerationError => e
      handle_error(-1, e.to_s)
    end

    def handle_error(status, error)
      @on_error.call(status, error)
    rescue StandardError => e
      logger.error("Error in on_error callback: #{e.message}")
    end
  end
end
