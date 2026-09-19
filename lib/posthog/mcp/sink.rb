# frozen_string_literal: true

module PostHog
  module MCP
    # The capture pipeline: stringify keys -> sanitize -> truncate -> fan out into
    # `$mcp_*` / `$exception` payloads -> `before_send` -> `PostHog::Client#capture`.
    #
    # Wraps a host-supplied client and never owns its lifecycle. Errors at any
    # stage are logged and the event dropped, never re-raised into tool code.
    #
    # @api private
    class Sink
      attr_reader :client

      def initialize(client)
        @client = client
      end

      # @param event [Hash] internal event (symbol or string keys)
      # @param options [Options, nil]
      # @return [Array<Hash>] the payloads handed to the client (for tests)
      def capture(event, options = nil)
        processed = process(event, options)
        return [] if processed.nil?

        processed.each { |payload| dispatch(payload) }
        processed
      rescue StandardError => e
        Log.debug(options, "Failed to capture PostHog event: #{e.message}")
        []
      end

      # Runs the full transform and returns the payloads that survived `before_send`.
      def process(event, options = nil)
        processed = Sanitization.stringify_keys(event)
        begin
          processed = Sanitization.sanitize_event(processed)
        rescue StandardError => e
          Log.debug(options, "Failed to sanitize event: #{e.message}")
          return nil
        end
        begin
          processed = Truncation.truncate_event(processed)
        rescue StandardError => e
          Log.debug(options, "Failed to truncate event: #{e.message}")
          return nil
        end
        processed['id'] = Ids.new_prefixed_id('evt') unless processed['id'].is_a?(String) && !processed['id'].empty?

        autocapture = options.nil? || options.enable_exception_autocapture
        payloads = EventBuilder.build(processed, enable_exception_autocapture: autocapture)
        apply_before_send(payloads, options)
      end

      private

      def apply_before_send(payloads, options)
        before_send = options&.before_send
        return payloads unless before_send

        payloads.filter_map do |payload|
          begin
            result = before_send.call(payload)
          rescue StandardError => e
            Log.debug(options, "before_send threw for event #{payload['event']}; dropping it: #{e.message}")
            next nil
          end
          result.is_a?(Hash) ? result : nil
        end
      end

      def dispatch(payload)
        properties = payload['properties'] || payload[:properties] || {}
        @client.capture(
          distinct_id: payload['distinct_id'] || payload[:distinct_id],
          event: payload['event'] || payload[:event],
          properties: properties,
          timestamp: payload['timestamp'] || payload[:timestamp] || Time.now.utc,
          uuid: Ids.uuid_v7,
          _lib: LIB_NAME,
          _lib_version: PostHog::VERSION
        )
      end
    end
  end
end
