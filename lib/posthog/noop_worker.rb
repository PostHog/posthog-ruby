# frozen_string_literal: true

module PostHog
  # A worker that doesn't consume jobs.
  #
  # @api private
  class NoopWorker
    # @param queue [Queue]
    def initialize(queue)
      @queue = queue
    end

    # @return [void]
    def run
      # Does nothing
    end

    # @return [Boolean]
    # TODO: Rename to `requesting?` in future version
    def is_requesting? # rubocop:disable Naming/PredicateName
      false
    end

    # @return [void]
    def request_flush
      # Does nothing
    end

    # @return [void]
    def notify
      # Does nothing
    end

    # @return [void]
    def shutdown
      # Does nothing
    end
  end
end
