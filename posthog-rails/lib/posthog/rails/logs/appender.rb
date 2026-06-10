# frozen_string_literal: true

require 'logger'
require 'time'
require 'posthog/internal/context'
require 'posthog/logging'
require 'posthog/rails/logs/severity'

module PostHog
  module Rails
    module Logs
      # A `Logger`-compatible sink that forwards each log record to an
      # OpenTelemetry logger as an OTLP log record.
      #
      # It is designed to be broadcast alongside the app's existing
      # `Rails.logger` so that ordinary `Rails.logger.info(...)` calls flow to
      # PostHog Logs in addition to the normal output. Each record is stamped
      # with the request-scoped PostHog identity captured by
      # {PostHog::Rails::RequestContext}.
      #
      # Thread-safety: intentionally lock-free apart from the optional rate
      # limiter's counter. Emitting touches no shared mutable state
      # (`@otel_logger` is assigned once, attributes are built per call, and
      # `Internal::Context.current` is thread/fiber-local), and the OTel
      # BatchLogRecordProcessor synchronizes its buffer internally — the same
      # split as stdlib `Logger`, which locks in `LogDevice`, not
      # `Logger#add`. A mutex around emit would serialize all app logging
      # needlessly.
      #
      # @api private
      class Appender < ::Logger
        SELF_LOG_PREFIX = '[posthog-ruby]'
        SELF_LOG_PROGNAME = 'PostHog'
        REQUEST_ATTRIBUTE_KEYS = %w[$current_url $request_method $request_path].freeze

        # @param otel_logger [#on_emit] An OpenTelemetry logger.
        # @param level [Integer, nil] Minimum severity to forward.
        # @param rate_limiter [PostHog::Rails::Logs::RateLimiter, nil] Optional cap on
        #   forwarded records, protecting the ingestion quota from runaway log volume.
        # @param before_send [#call, nil] Optional callback invoked with each record hash
        #   (:timestamp, :severity_number, :severity_text, :body, :attributes) before it
        #   is emitted. Return a (possibly modified) hash to send, or nil to drop —
        #   useful for scrubbing PII. If the callback raises, the record is dropped.
        def initialize(otel_logger, level: nil, rate_limiter: nil, before_send: nil)
          super(nil)
          @otel_logger = otel_logger
          @rate_limiter = rate_limiter
          @before_send = before_send
          self.level = level unless level.nil?
        end

        # Mirrors `Logger#add` message/progname resolution, then emits to OTel
        # instead of writing to a log device.
        #
        # @return [Boolean] Always true so it composes with broadcast loggers.
        def add(severity, message = nil, progname = nil)
          severity ||= ::Logger::UNKNOWN
          return true if severity < level

          if message.nil?
            if block_given?
              message = yield
            else
              message = progname
              progname = nil
            end
          end

          return true if message.nil?
          return true if self_log?(message, progname)

          case @rate_limiter&.record
          when :reject
            return true
          when :reject_first
            # One discoverable notice per window so truncation isn't silent.
            emit(
              ::Logger::WARN,
              "PostHog Logs rate cap reached (#{@rate_limiter.limit} records/minute); " \
              'dropping further records for the remainder of this window',
              nil
            )
            return true
          end

          emit(severity, message, progname)
          true
        rescue StandardError
          # Never let log forwarding break the calling code path.
          true
        end

        private

        def emit(severity, message, progname)
          severity_number, severity_text = Severity.for(severity)
          record = {
            timestamp: Time.now,
            severity_number: severity_number,
            severity_text: severity_text,
            body: body_for(message),
            attributes: attributes_for(progname)
          }
          record = apply_before_send(record)
          return if record.nil?

          @otel_logger.on_emit(**record)
        end

        # Runs after the rate-cap check so a log flood does not pay scrubbing
        # costs for records that would be dropped anyway.
        #
        # Unlike the events before_send (which sends the original event when the
        # callback raises), a failing callback drops the record: the likeliest
        # use is PII scrubbing, where shipping the unscrubbed original is worse
        # than losing the line.
        def apply_before_send(record)
          return record unless @before_send

          result = @before_send.call(record)
          result.is_a?(Hash) ? result : nil
        rescue StandardError => e
          warn_before_send_error(e)
          nil
        end

        def warn_before_send_error(error)
          # Benign race: concurrent first failures may warn more than once.
          return if @before_send_error_warned

          @before_send_error_warned = true
          PostHog::Logging.logger.warn(
            "logs_before_send raised (#{error.class}: #{error.message}); dropping records that fail the callback"
          )
        end

        def body_for(message)
          message.is_a?(String) ? message : message.inspect
        end

        def attributes_for(progname)
          attributes = {}
          attributes['logger.progname'] = progname.to_s if progname

          context = Internal::Context.current
          return attributes unless context

          attributes['posthogDistinctId'] = context.distinct_id if context.distinct_id
          attributes['sessionId'] = context.session_id if context.session_id

          properties = context.properties || {}
          REQUEST_ATTRIBUTE_KEYS.each do |key|
            value = properties[key] || properties[key.to_sym]
            attributes[key] = value if value
          end

          attributes
        end

        def self_log?(message, progname)
          return true if progname.to_s == SELF_LOG_PROGNAME

          # PrefixedLogger always places the prefix at the start of the message,
          # so start_with? suffices and avoids suppressing app logs that merely
          # mention the SDK mid-string.
          message.is_a?(String) && message.start_with?(SELF_LOG_PREFIX)
        end
      end
    end
  end
end
