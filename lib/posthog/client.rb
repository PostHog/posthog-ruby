require 'thread'
require 'time'

require 'posthog/defaults'
require 'posthog/logging'
require 'posthog/utils'
require 'posthog/worker'

class PostHog
  class Client
    include PostHog::Utils
    include PostHog::Logging

    # @param [Hash] opts
    # @option opts [String] :api_key Your project's api_key
    # @option opts [FixNum] :max_queue_size Maximum number of calls to be
    #   remain queued.
    # @option opts [Proc] :on_error Handles error calls from the API.
    def initialize(opts = {})
      symbolize_keys!(opts)

      @queue = Queue.new
      @api_key = opts[:api_key]
      @max_queue_size = opts[:max_queue_size] || Defaults::Queue::MAX_SIZE
      @worker_mutex = Mutex.new
      @worker = Worker.new(@queue, @api_key, opts)
      @worker_thread = nil

      check_api_key!

      at_exit { @worker_thread && @worker_thread[:should_exit] = true }
    end

    # Synchronously waits until the worker has flushed the queue.
    #
    # Use only for scripts which are not long-running, and will specifically
    # exit
    def flush
      while !@queue.empty? || @worker.is_requesting?
        ensure_worker_running
        sleep(0.1)
      end
    end

    # @!macro common_attrs
    #   @option attrs [String] :message_id ID that uniquely
    #     identifies a message across the API. (optional)
    #   @option attrs [Time] :timestamp When the event occurred (optional)
    #   @option attrs [String] :distinct_id The ID for this user in your database

    # Captures an event
    #
    # @param [Hash] attrs
    #
    # @option attrs [String] :event Event name
    # @option attrs [Hash] :properties Event properties (optional)
    # @macro common_attrs
    def capture(attrs)
      symbolize_keys! attrs
      enqueue(FieldParser.parse_for_capture(attrs))
    end

    # Identifies a user
    #
    # @param [Hash] attrs
    #
    # @option attrs [Hash] :properties User properties (optional)
    # @macro common_attrs
    def identify(attrs)
      symbolize_keys! attrs
      enqueue(FieldParser.parse_for_identify(attrs))
    end

    # Aliases a user from one id to another
    #
    # @param [Hash] attrs
    #
    # @option attrs [String] :alias The alias to give the distinct id
    # @macro common_attrs
    def alias(attrs)
      symbolize_keys! attrs
      enqueue(FieldParser.parse_for_alias(attrs))
    end

    # @return [Fixnum] number of messages in the queue
    def queued_messages
      @queue.length
    end

    private

    # private: Enqueues the action.
    #
    # returns Boolean of whether the item was added to the queue.
    def enqueue(action)
      # add our request id for tracing purposes
      action[:messageId] ||= uid

      if @queue.length < @max_queue_size
        @queue << action
        ensure_worker_running

        true
      else
        logger.warn(
          'Queue is full, dropping events. The :max_queue_size ' \
          'configuration parameter can be increased to prevent this from ' \
          'happening.'
        )
        false
      end
    end

    # private: Checks that the api_key is properly initialized
    def check_api_key!
      raise ArgumentError, 'API key must be initialized' if @api_key.nil?
    end

    def ensure_worker_running
      return if worker_running?
      @worker_mutex.synchronize do
        return if worker_running?
        @worker_thread = Thread.new do
          @worker.run
        end
      end
    end

    def worker_running?
      @worker_thread && @worker_thread.alive?
    end
  end
end

