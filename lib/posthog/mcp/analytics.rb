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
      # request by {Instrumentation}; outside of one (or over stdio, where a
      # server only ever talks to one client) it is the server's current session.
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

      def current_session_id(data)
        scope = RequestScope.current
        scoped = scope.is_a?(Hash) ? scope[:session_id] : nil
        scoped || data.session_id
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
