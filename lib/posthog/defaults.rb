class PostHog
  module Defaults

    MAX_HASH_SIZE = 50_000

    module Request
      HOST = 'app.posthog.com'
      PORT = 443
      PATH = '/batch/'
      SSL = true
      HEADERS = {
        'Accept' => 'application/json',
        'Content-Type' => 'application/json',
        'User-Agent' => "posthog-ruby/#{PostHog::VERSION}"
      }
      RETRIES = 10
    end

    module FeatureFlags
      FLAG_REQUEST_TIMEOUT_SECONDS = 3
    end
    
    module Queue
      MAX_SIZE = 10_000
    end

    module Message
      MAX_BYTES = 32_768 # 32Kb
    end

    module MessageBatch
      MAX_BYTES = 512_000 # 500Kb
      MAX_SIZE = 100
    end

    module BackoffPolicy
      MIN_TIMEOUT_MS = 100
      MAX_TIMEOUT_MS = 10_000
      MULTIPLIER = 1.5
      RANDOMIZATION_FACTOR = 0.5
    end
  end
end
