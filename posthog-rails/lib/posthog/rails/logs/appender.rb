# frozen_string_literal: true

require 'logger'
require 'time'
require 'posthog/internal/context'
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
      # Thread-safety: intentionally lock-free. Emitting touches no shared
      # mutable state (`@otel_logger` is assigned once, attributes are built
      # per call, and `Internal::Context.current` is thread/fiber-local), and
      # the OTel BatchLogRecordProcessor synchronizes its buffer internally —
      # the same split as stdlib `Logger`, which locks in `LogDevice`, not
      # `Logger#add`. A mutex here would serialize all app logging needlessly.
      #
      # @api private
      class Appender < ::Logger
        SELF_LOG_PREFIX = '[posthog-ruby]'
        SELF_LOG_PROGNAME = 'PostHog'
        REQUEST_ATTRIBUTE_KEYS = %w[$current_url $request_method $request_path].freeze

        # @param otel_logger [#on_emit] An OpenTelemetry logger.
        # @param level [Integer, nil] Minimum severity to forward.
        def initialize(otel_logger, level: nil)
          super(nil)
          @otel_logger = otel_logger
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

          emit(severity, message, progname)
          true
        rescue StandardError
          # Never let log forwarding break the calling code path.
          true
        end

        private

        def emit(severity, message, progname)
          severity_number, severity_text = Severity.for(severity)
          @otel_logger.on_emit(
            timestamp: Time.now,
            severity_number: severity_number,
            severity_text: severity_text,
            body: body_for(message),
            attributes: attributes_for(progname)
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
