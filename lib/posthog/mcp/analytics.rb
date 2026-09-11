# frozen_string_literal: true

module PostHog
  module MCP
    # Handle returned by {PostHog::MCP.instrument}. Emits custom events onto the
    # same pipeline as the auto-captured `$mcp_*` events.
    #
    # @note Experimental.
    class Analytics
      # @api private
      def initialize(server)
        @server = server
      end

      # Capture a custom event scoped to the current MCP session. The event
      # name is sent verbatim (a customer event, not `$`-prefixed).
      #
      # Inside a tool body the session is the one pinned to the in-flight
      # request by {Instrumentation}. Over stdio, where a server only ever talks
      # to one client, it is the server's current session. On an HTTP server a
      # call that has lost the request scope gets a standalone session rather
      # than the server's, which may belong to another caller's request.
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

        Instrumentation.capture_event(data, {
                                        'session_id' => current_session_id(data),
                                        'event_type' => EventType::CUSTOM,
                                        'event_name' => event,
                                        'timestamp' => Time.now.utc,
                                        'properties' => properties
                                      })
        nil
      end

      # Flush the underlying PostHog client.
      #
      # @return [void]
      def flush
        data = PostHog::MCP.tracking_data(@server)
        client = data&.sink&.client
        client.flush if client.respond_to?(:flush)
        nil
      end

      private

      # The session pinned to the in-flight request, when there is one. On a server
      # that has served an HTTP request the server-wide session is not a safe
      # fallback: it belongs to whichever request settled it last, which under
      # concurrency is somebody else's. That happens when a tool hands its work to
      # a thread or fiber it spawned on Ruby 3.0/3.1, where {RequestScope} is
      # fiber-local and is not inherited. Fail closed with a standalone session
      # rather than filing the event under another caller's identity; over stdio a
      # server only ever talks to one client, so the fallback stays.
      def current_session_id(data)
        scope = RequestScope.current
        scoped = scope.is_a?(Hash) ? scope[:session_id] : nil
        return scoped if scoped
        return data.session_id unless data.http_transport_seen

        warn_unscoped_capture(data)
        Session.new_session_id
      end

      def warn_unscoped_capture(data)
        return if data.warned_unscoped_capture

        data.warned_unscoped_capture = true
        Log.warn(
          data.options,
          'Warning: analytics.capture() ran without the scope of the request that started it, so its event got ' \
          'a standalone $session_id instead of the caller\'s. On Ruby 3.2+ the scope follows threads and fibers ' \
          'a tool spawns; before that it does not, so capture custom events from the tool body itself.'
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
