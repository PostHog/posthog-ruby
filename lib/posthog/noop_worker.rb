# A worker that doesn't consume jobs
class PostHog
  class NoopWorker
    def initialize(queue)
      @queue = queue
    end

    def run
      # Does nothing
    end

    def is_requesting?
      false
    end
  end
end
