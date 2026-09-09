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
      end

      def get(session_id)
        identity = @cache.delete(session_id)
        return nil if identity.nil?

        @cache[session_id] = identity
      end

      def set(session_id, identity)
        @cache.delete(session_id)
        @cache.shift if @cache.length >= @max_size && !@cache.key?(session_id)
        @cache[session_id] = identity
      end

      def has?(session_id)
        @cache.key?(session_id)
      end

      def size
        @cache.length
      end
    end

    # Identity resolution: runs the `identify` option, dedupes against the
    # per-server cache, and decides when a standalone `$identify` event fires.
    #
    # @api private
    module Identity
      module_function

      def identities_equal?(first, second)
        return false if first.distinct_id != second.distinct_id
        return false if sorted_json(first.groups || {}) != sorted_json(second.groups || {})

        a_props = first.properties || {}
        b_props = second.properties || {}
        return false if a_props.keys.map(&:to_s).sort != b_props.keys.map(&:to_s).sort

        a_props.all? do |key, value|
          other = if b_props.key?(key)
                    b_props[key]
                  else
                    b_props[key.is_a?(Symbol) ? key.to_s : key.to_s.to_sym]
                  end
          sorted_json(value) == sorted_json(other)
        end
      end

      def merge_identities(previous, nxt)
        return nxt if previous.nil?

        UserIdentity.new(
          distinct_id: nxt.distinct_id,
          properties: (previous.properties || {}).merge(nxt.properties || {}),
          groups: nxt.groups.nil? ? previous.groups : nxt.groups
        )
      end

      # Resolve the optional `identify` callback and return an `$identify` event
      # to emit only when the identity has materially changed (else nil).
      def handle_identify(data, session_id, request, extra)
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
          return nil
        end

        previous = data.identified_sessions.get(session_id)
        merged = merge_identities(previous, identity)
        changed = !(previous && identities_equal?(previous, merged))
        data.identified_sessions.set(session_id, merged)
        return nil unless changed

        Log.debug(data.options, "Identified session #{session_id}")
        {
          'session_id' => session_id,
          'resource_name' => request_resource_name(request),
          'event_type' => EventType::IDENTIFY,
          'parameters' => { 'request' => request, 'extra' => captured_extra(extra) },
          'timestamp' => Time.now.utc
        }
      rescue StandardError => e
        Log.debug(data.options, "Error: identify function threw while identifying session #{session_id} - #{e.message}")
        nil
      end

      def request_resource_name(request)
        return 'Unknown' unless request.is_a?(Hash)

        params = request[:params] || request['params']
        return 'Unknown' unless params.is_a?(Hash)

        name = params[:name] || params['name']
        name.is_a?(String) ? name : 'Unknown'
      end

      # Only JSON scalars from `extra` are captured; never opaque transport objects.
      def captured_extra(extra)
        return nil unless extra.is_a?(Hash)

        extra.select do |_, value|
          value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
        end
      end

      def sorted_json(value)
        JSON.generate(sort_deep(value))
      rescue StandardError
        value.to_s
      end

      def sort_deep(value)
        case value
        when Hash then value.map { |k, v| [k.to_s, sort_deep(v)] }.sort_by(&:first).to_h
        when Array then value.map { |v| sort_deep(v) }
        when String, Numeric, true, false, nil then value
        else value.to_s
        end
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
