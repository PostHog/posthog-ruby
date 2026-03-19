# frozen_string_literal: true

module PostHog
  # Interface for external caching of feature flag definitions.
  #
  # EXPERIMENTAL: This API may change in future minor version bumps.
  #
  # Enables multi-worker environments (Kubernetes, load-balanced servers,
  # serverless functions) to share flag definitions via an external cache,
  # reducing redundant API calls.
  #
  # Implement the four required methods on any object and pass it as the
  # +:flag_definition_cache_provider+ option when creating a {Client}.
  #
  # == Required Methods
  #
  # [+flag_definitions+]
  #   Retrieve cached flag definitions. Return a Hash with +:flags+,
  #   +:group_type_mapping+, and +:cohorts+ keys, or +nil+ if the cache
  #   is empty. Returning +nil+ triggers an API fetch when no flags are
  #   loaded yet (emergency fallback).
  #
  # [+should_fetch_flag_definitions?+]
  #   Return +true+ if this instance should fetch new definitions from the
  #   API, +false+ to read from cache instead. Use for distributed lock
  #   coordination so only one worker fetches at a time.
  #
  # [+on_flag_definitions_received(data)+]
  #   Called after successfully fetching new definitions from the API.
  #   +data+ is a Hash with +:flags+, +:group_type_mapping+, and +:cohorts+
  #   keys (plain Ruby types, not Concurrent:: wrappers). Store it in your
  #   external cache.
  #
  # [+shutdown+]
  #   Called when the PostHog client shuts down. Release any distributed
  #   locks and clean up resources.
  #
  # == Error Handling
  #
  # All methods are wrapped in +begin/rescue+. Errors are logged but never
  # break flag evaluation:
  # - +should_fetch_flag_definitions?+ errors default to fetching (fail-safe)
  # - +flag_definitions+ errors fall back to API fetch
  # - +on_flag_definitions_received+ errors are logged; flags remain in memory
  # - +shutdown+ errors are logged; shutdown continues
  #
  # == Example
  #
  #   cache = RedisFlagCache.new(redis, service_key: 'my-service')
  #   client = PostHog::Client.new(
  #     api_key: '<project_api_key>',
  #     personal_api_key: '<personal_api_key>',
  #     flag_definition_cache_provider: cache
  #   )
  #
  module FlagDefinitionCacheProvider
    REQUIRED_METHODS = %i[
      flag_definitions
      should_fetch_flag_definitions?
      on_flag_definitions_received
      shutdown
    ].freeze

    # Validates that +provider+ implements all required methods.
    # Raises +ArgumentError+ listing any missing methods.
    #
    # @param provider [Object] the cache provider to validate
    # @raise [ArgumentError] if any required methods are missing
    def self.validate!(provider)
      missing = REQUIRED_METHODS.reject { |m| provider.respond_to?(m) }
      return if missing.empty?

      raise ArgumentError,
            "Flag definition cache provider is missing required methods: #{missing.join(', ')}. " \
            'See PostHog::FlagDefinitionCacheProvider for the required interface.'
    end
  end
end
