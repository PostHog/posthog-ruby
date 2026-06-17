# frozen_string_literal: true

module PostHog
  module Rails
    module Logs
      # Fixed-window rate limiter protecting the PostHog Logs ingestion quota
      # from runaway log volume (PostHog Logs bills by data ingested).
      #
      # Thread-safe: the counter is the one piece of shared mutable state in
      # the logs pipeline, guarded by a mutex scoped to a counter bump.
      #
      # @api private
      class RateLimiter
        WINDOW_SECONDS = 60

        # @return [Integer] Maximum records allowed per window.
        attr_reader :limit

        # @param limit [Integer] Maximum records allowed per {WINDOW_SECONDS} window.
        def initialize(limit)
          @limit = limit
          @mutex = Mutex.new
          @window = nil
          @count = 0
        end

        # Records one attempt and returns the verdict.
        #
        # @return [Symbol] :allow when under the cap, :reject_first for the
        #   first rejection of a window (callers may emit a single notice),
        #   :reject thereafter.
        def record
          @mutex.synchronize do
            window = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i / WINDOW_SECONDS
            if window != @window
              @window = window
              @count = 0
            end
            @count += 1
            next :allow if @count <= @limit

            @count == @limit + 1 ? :reject_first : :reject
          end
        end
      end
    end
  end
end
