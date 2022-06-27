require 'posthog/defaults'
require 'posthog/message_batch'
require 'posthog/transport'
require 'posthog/utils'

class PostHog
  class SendWorker
    include PostHog::Utils
    include PostHog::Defaults
    include PostHog::Logging

    # public: Creates a new worker
    #
    # The worker continuously takes messages off the queue
    # and makes requests to the posthog.com api
    #
    # queue   - Queue synchronized between client and worker
    # api_key  - String of the project's API key
    # options - Hash of worker options
    #           batch_size - Fixnum of how many items to send in a batch
    #           on_error   - Proc of what to do on an error
    #
    def initialize(queue, api_key, options = {})
      symbolize_keys! options
      @queue = queue
      @api_key = api_key
      @on_error = options[:on_error] || proc { |status, error| }
      batch_size = options[:batch_size] || Defaults::MessageBatch::MAX_SIZE
      @batch = MessageBatch.new(batch_size)
      @lock = Mutex.new
      @transport = Transport.new api_host: options[:api_host], skip_ssl_verification: options[:skip_ssl_verification]
    end

    # public: Continuously runs the loop to check for new events
    #
    def run
      until Thread.current[:should_exit]
        return if @queue.empty?

        @lock.synchronize do
          consume_message_from_queue! until @batch.full? || @queue.empty?
        end

        res = @transport.send @api_key, @batch
        @on_error.call(res.status, res.error) unless res.status == 200

        @lock.synchronize { @batch.clear }
      end
    ensure
      @transport.shutdown
    end

    # public: Check whether we have outstanding requests.
    #
    def is_requesting?
      @lock.synchronize { !@batch.empty? }
    end

    private

    def consume_message_from_queue!
      @batch << @queue.pop
    rescue MessageBatch::JSONGenerationError => e
      @on_error.call(-1, e.to_s)
    end
  end
end
