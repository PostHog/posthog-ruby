# frozen_string_literal: true

module PostHog
  module MCP
    # Handle returned by {PostHog::MCP.instrument}. Emits custom events onto the
    # same pipeline as the auto-captured `$mcp_*` events.
    #
    # @note Experimental.
    class Analytics
      FLUSH_TIMEOUT_SECONDS = 10
      private_constant :FLUSH_TIMEOUT_SECONDS
      MAX_HELD_EVENTS = 1000
      private_constant :MAX_HELD_EVENTS

      # @api private
      def initialize(server)
        @server = server
      end

      # Capture a custom event scoped to the current MCP session. The event
      # name is sent verbatim (a customer event, not `$`-prefixed).
      #
      # Inside a tool body the session and the identity are the ones pinned to
      # the in-flight request by {Instrumentation}, so a concurrent request on
      # the same session cannot reattribute this event. Over stdio, where a
      # server only ever talks to one client, the session is the server's
      # current one. On an HTTP server a call that has lost the request scope
      # gets a standalone session rather than the server's, which may belong to
      # another caller's request.
      #
      # @param event [String] event name
      # @param properties [Hash] event properties
      # @return [void]
      # @raise [ArgumentError] when the event name is blank
      def capture(event, properties = {})
        unless event.is_a?(String) && !event.strip.empty?
          raise ArgumentError, 'capture() requires an event name, e.g. analytics.capture("feedback_submitted")'
        end

        data = PostHog::MCP.tracking_data(@server)
        return if data.nil?

        scope = RequestScope.current
        scope = nil unless scope.is_a?(Hash)
        input = { 'event_type' => EventType::CUSTOM, 'event_name' => event, 'timestamp' => Time.now.utc,
                  'properties' => properties }
        return if hold(data, scope, input)

        session_id, source = current_session(data, scope)
        Instrumentation.capture_event(data, input.merge('session_id' => session_id, 'session_source' => source),
                                      actor: scoped_actor(scope))
        nil
      end

      # Flush the underlying PostHog client. Never raises: a failed or timed-out
      # flush is logged instead.
      #
      # @return [void]
      def flush
        data = PostHog::MCP.tracking_data(@server)
        client = data&.sink&.client
        return unless client.respond_to?(:flush)

        flushed = client.flush(timeout: FLUSH_TIMEOUT_SECONDS)
        if flushed == false
          Log.warn(data.options,
                   "PostHog client flush did not finish within #{FLUSH_TIMEOUT_SECONDS}s")
        end
        nil
      rescue StandardError => e
        Log.warn(data&.options, "Failed to flush PostHog client: #{e.class}: #{e.message}")
        nil
      end

      private

      # The session pinned to the in-flight request, when there is one. On a server
      # that has served an HTTP request the server-wide session is not a safe
      # fallback: it belongs to whichever request settled it last, which under
      # concurrency is somebody else's. That happens when a tool hands its work to
      # a thread that did not inherit the request's fiber storage, such as a pool
      # created before the request. Fail closed with a standalone session
      # rather than filing the event under another caller's identity; over stdio a
      # server only ever talks to one client, so the fallback stays.
      def current_session(data, scope)
        return scope.values_at(:session_id, :session_source) if scope&.[](:session_id)
        return [data.session_id, data.session_source] unless data.http_transport_seen

        warn_unscoped_capture(data)
        [Session.new_session_id, 'generated']
      end

      def hold(data, scope, input)
        return false unless scope&.key?(:held)

        data.synchronize do
          held = scope[:held]
          next false unless held

          if held.size < MAX_HELD_EVENTS
            held << input.merge('properties' => input['properties'].dup, 'duration' => 0)
            next true
          end

          unless scope[:overflowed_held]
            scope[:overflowed_held] = true
            Log.warn(data.options, "Warning: a tool call captured more than #{MAX_HELD_EVENTS} custom events " \
                                   'before its conversation handle was delivered; sending the rest with the ' \
                                   'session the call has so far')
          end
          false
        end
      end

      # The identity the in-flight request resolved, which {Instrumentation} pinned
      # on the scope before running the tool body. Absent outside a request it
      # started, and only then is the session-keyed cache consulted instead.
      def scoped_actor(scope)
        scope&.key?(:actor) ? scope[:actor] : Instrumentation::UNRESOLVED_ACTOR
      end

      def warn_unscoped_capture(data)
        return if data.warned_unscoped_capture

        data.warned_unscoped_capture = true
        Log.warn(
          data.options,
          'Warning: analytics.capture() ran without the scope of the request that started it, so its event got ' \
          'a standalone $session_id instead of the caller\'s. The scope follows threads and fibers a tool ' \
          'spawns, but not work handed to a thread created outside the request, such as an existing pool.'
        )
      end
    end

    # Returned when instrumentation could not be set up; every call is a no-op.
    #
    # @api private
    class NoopAnalytics < Analytics
      def initialize
        super(nil)
      end

      def capture(_event = nil, _properties = {})
        nil
      end

      def flush
        nil
      end
    end
  end
end
