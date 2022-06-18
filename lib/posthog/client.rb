require 'thread'
require 'time'

require 'posthog/defaults'
require 'posthog/logging'
require 'posthog/utils'
require 'posthog/worker'
require 'posthog/noop_worker'
require 'posthog/feature_flags'

class PostHog
  class Client
    include PostHog::Utils
    include PostHog::Logging

    # @param [Hash] opts
    # @option opts [String] :api_key Your project's api_key
    # @option opts [FixNum] :max_queue_size Maximum number of calls to be
    #   remain queued. Defaults to 10_000.
    # @option opts [Bool] :test_mode +true+ if messages should remain
    #   queued for testing. Defaults to +false+.
    # @option opts [Proc] :on_error Handles error calls from the API.
    def initialize(opts = {})
      symbolize_keys!(opts)

      @queue = Queue.new
      @api_key = opts[:api_key]
      @max_queue_size = opts[:max_queue_size] || Defaults::Queue::MAX_SIZE
      @worker_mutex = Mutex.new
      if opts[:test_mode]
        @worker = NoopWorker.new(@queue)
      else
        @worker = Worker.new(@queue, @api_key, opts)
      end
      @worker_thread = nil
      @feature_flags_poller = nil
      @personal_api_key = nil

      check_api_key!

      if opts[:personal_api_key]
        @personal_api_key = opts[:personal_api_key]
        @feature_flags_poller =
          FeatureFlagsPoller.new(
            opts[:feature_flags_polling_interval],
            opts[:personal_api_key],
            @api_key,
            opts[:host]
          )
      end

      at_exit { @worker_thread && @worker_thread[:should_exit] = true }
    end

    # Synchronously waits until the worker has cleared the queue.
    #
    # Use only for scripts which are not long-running, and will specifically
    # exit
    def flush
      while !@queue.empty? || @worker.is_requesting?
        ensure_worker_running
        sleep(0.1)
      end
    end

    # Clears the queue without waiting.
    #
    # Use only in test mode
    def clear
      @queue.clear
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

    # @return [Hash] pops the last message from the queue
    def dequeue_last_message
      @queue.pop
    end

    # @return [Fixnum] number of messages in the queue
    def queued_messages
      @queue.length
    end

    def is_feature_enabled(flag_key, distinct_id, default_value = false)
      unless @personal_api_key
        logger.error(
          'You need to specify a personal_api_key to use feature flags'
        )
        return
      end
      is_enabled =
        @feature_flags_poller.is_feature_enabled(
          flag_key,
          distinct_id,
          default_value
        )
      capture(
        {
          'distinct_id': distinct_id,
          'event': '$feature_flag_called',
          'properties': {
            '$feature_flag': flag_key,
            '$feature_flag_response': is_enabled
          }
        }
      )
      return is_enabled
    end

    def reload_feature_flags
      unless @personal_api_key
        logger.error(
          'You need to specify a personal_api_key to use feature flags'
        )
        return
      end
      @feature_flags_poller.load_feature_flags(true)
    end

    def shutdown
      @feature_flags_poller.shutdown_poller
      flush
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
        @worker_thread = Thread.new { @worker.run }
      end
    end

    def worker_running?
      @worker_thread && @worker_thread.alive?
    end
  end
end
