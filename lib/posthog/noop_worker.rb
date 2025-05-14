# A worker that doesn't consume jobs
class PostHog
  class NoopWorker
    def initialize(queue)
      @queue = queue
    end

    def run
      # Does nothing
    end

    # TODO: Rename to `requesting?` in future version
    def is_requesting? # rubocop:disable Naming/PredicateName
      false
    end
  end
end
