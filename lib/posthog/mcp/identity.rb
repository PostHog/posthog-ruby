# frozen_string_literal: true

require 'json'

module PostHog
  module MCP
    # Bounded LRU of session identities, isolated per server.
    #
    # @api private
    class IdentityCache
      def initialize(max_size = 1000)
        @cache = {}
        @max_size = max_size
        @mutex = Mutex.new
      end

      def get(session_id)
        @mutex.synchronize do
          identity = @cache.delete(session_id)
          next nil if identity.nil?

          @cache[session_id] = identity
        end
      end

      def set(session_id, identity)
        @mutex.synchronize do
          @cache.delete(session_id)
          @cache.shift if @cache.length >= @max_size
          @cache[session_id] = identity
        end
      end

      # Atomically read the cached identity, merge the new one, and store it.
      # Keeps concurrent requests for one session from interleaving their
      # read-merge-write.
      #
      # @return [UserIdentity] the merged identity
      def merge!(session_id, identity)
        @mutex.synchronize do
          merged = Identity.merge_identities(@cache.delete(session_id), identity)
          @cache.shift if @cache.length >= @max_size
          @cache[session_id] = merged
        end
      end

      def has?(session_id)
        @mutex.synchronize { @cache.key?(session_id) }
      end

      def size
        @mutex.synchronize { @cache.length }
      end
    end

    # Identity resolution: runs the `identify` option and merges the result into
    # the per-server cache.
    #
    # @api private
    module Identity
      module_function

      def merge_identities(previous, nxt)
        return nxt if previous.nil?

        UserIdentity.new(
          distinct_id: nxt.distinct_id,
          properties: (previous.properties || {}).merge(nxt.properties || {}),
          groups: nxt.groups.nil? ? previous.groups : nxt.groups
        )
      end

      # Resolve the optional `identify` callback for one request: the identity the
      # request's events belong to.
      #
      # The actor is handed back rather than left for the caller to read out of
      # {IdentityCache} later. The cache is keyed by session, and a request's
      # events are built after its handler returns, so a concurrent request on
      # the same session would otherwise decide who this one is attributed to.
      # When resolution yields nothing the cache is read once, here, so whatever
      # a request is attributed to it is attributed to consistently.
      #
      # @return [UserIdentity, nil]
      def resolve(data, session_id, request, extra)
        identify = data.options.identify
        return nil unless identify

        result = if identify.is_a?(UserIdentity) || identify.is_a?(Hash)
                   identify
                 else
                   Callbacks.call(identify, request,
                                  extra)
                 end
        identity = UserIdentity.coerce(result)
        unless identity
          Log.debug(data.options, "Warning: Supplied identify function returned null for session #{session_id}")
          return data.identified_sessions.get(session_id)
        end

        data.identified_sessions.merge!(session_id, identity)
      rescue StandardError => e
        Log.debug(data.options, "Error: identify function threw while identifying session #{session_id} - #{e.message}")
        data.identified_sessions.get(session_id)
      end
    end

    # Invokes user callbacks with `(request, extra)`, tolerating 1-arity lambdas.
    #
    # @api private
    module Callbacks
      module_function

      def call(callable, request, extra)
        arity = callable.respond_to?(:arity) ? callable.arity : 2
        case arity
        when 0 then callable.call
        when 1 then callable.call(request)
        else callable.call(request, extra)
        end
      end
    end
  end
end
