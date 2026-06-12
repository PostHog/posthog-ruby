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
        # Maps PostHog event-property names (as stored in Internal::Context) to
        # the OTel semantic-convention attribute names used on log records,
        # matching the web SDK so one filter works across SDKs.
        REQUEST_ATTRIBUTE_NAMES = {
          '$current_url' => 'url.full',
          '$request_method' => 'http.request.method',
          '$request_path' => 'url.path'
        }.freeze

        # @param otel_logger [#on_emit] An OpenTelemetry logger.
        # @param level [Integer, nil] Minimum severity to forward.
        # @param rate_limiter [PostHog::Rails::Logs::RateLimiter, nil] Optional cap on
        #   forwarded records, protecting the ingestion quota from runaway log volume.
        # @param before_send [#call, nil] Optional callback invoked with each record hash
        #   (:timestamp, :severity, :body, :attributes — where :severity is a symbol such
        #   as :warn) before it is emitted. Return a (possibly modified) hash to send, or
        #   nil to drop — useful for scrubbing PII. If the callback raises, the record is
        #   dropped.
        def initialize(otel_logger, level: nil, rate_limiter: nil, before_send: nil)
          super(nil)
          @otel_logger = otel_logger
          @rate_limiter = rate_limiter
          @before_send = before_send
          # The forwarding threshold deliberately does NOT live in Logger#level.
          # Rails 7.1+ BroadcastLogger computes #level as the min and #debug?
          # etc. as the any? across sinks, so storing it there would widen the
          # app-wide predicates (logs_level = :debug would flip
          # Rails.logger.debug? true and make e.g. ActiveRecord start
          # generating SQL debug lines), and a broadcast-wide
          # `Rails.logger.level =` would clobber the configured logs_level.
          # Pinning the inherited level to UNKNOWN keeps this sink invisible
          # to those calculations; filtering happens against @threshold in #add.
          @threshold = level || ::Logger::DEBUG
          self.level = ::Logger::UNKNOWN
        end

        # Mirrors `Logger#add` message/progname resolution, then emits to OTel
        # instead of writing to a log device.
        #
        # @return [Boolean] Always true so it composes with broadcast loggers.
        def add(severity, message = nil, progname = nil)
          severity ||= ::Logger::UNKNOWN
          return true if severity < @threshold

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

          record = apply_before_send(build_record(severity, message, progname))
          return true if record.nil?

          case @rate_limiter&.record
          when :reject
            return true
          when :reject_first
            emit_rate_cap_notice
            return true
          end

          emit(record)
          true
        rescue StandardError
          # Never let log forwarding break the calling code path.
          true
        end

        private

        def build_record(severity, message, progname)
          {
            timestamp: Time.now,
            severity: Severity.name_for(severity),
            body: body_for(message),
            attributes: attributes_for(progname)
          }
        end

        def emit(record)
          # The before_send callback sees a single :severity enum; the OTel
          # number/text pair is derived here so the two can never be set
          # inconsistently.
          severity_number, severity_text = Severity.for_name(record[:severity])
          @otel_logger.on_emit(
            timestamp: record[:timestamp],
            severity_number: severity_number,
            severity_text: severity_text,
            body: record[:body],
            attributes: record[:attributes]
          )
        end

        # One discoverable notice per window so truncation isn't silent. Emitted
        # directly (bypassing before_send) so a scrubber can't accidentally
        # suppress the only signal that records are being dropped.
        def emit_rate_cap_notice
          emit(
            timestamp: Time.now,
            severity: :warn,
            body: "PostHog Logs rate cap reached (#{@rate_limiter.limit} records/minute); " \
                  'dropping further records for the remainder of this window',
            attributes: {}
          )
        end

        # Runs before the rate-cap check (matching the other PostHog SDKs) so
        # records dropped by the callback never consume window budget — a
        # before_send that drops noisy logs must not starve the legitimate
        # records behind them.
        #
        # Unlike the events before_send (which sends the original event when the
        # callback raises), a failing callback drops the record: the likeliest
        # use is PII scrubbing, where shipping the unscrubbed original is worse
        # than losing the line.
        def apply_before_send(record)
          return record unless @before_send

          result = @before_send.call(record)
          return result if result.is_a?(Hash)

          # nil is an intentional drop and stays silent; any other type is
          # likely a bug (e.g. a proc whose last expression isn't the record).
          warn_before_send("returned #{result.class} instead of a Hash or nil") unless result.nil?
          nil
        rescue StandardError => e
          warn_before_send("raised (#{e.class}: #{e.message})")
          nil
        end

        def warn_before_send(description)
          # Benign race: concurrent first failures may warn more than once.
          return if @before_send_warned

          @before_send_warned = true
          PostHog::Logging.logger.warn("logs_before_send #{description}; dropping the record")
        end

        def body_for(message)
          str = message.is_a?(String) ? message.dup : message.inspect
          str = str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless str.encoding == Encoding::UTF_8
          str.valid_encoding? ? str : str.scrub
        end

        def attributes_for(progname)
          attributes = {}
          # Ruby's progname is the closest analog to the OTel-world "logger name";
          # logger.name is the key users coming from other ecosystems will expect.
          attributes['logger.name'] = progname.to_s if progname

          context = Internal::Context.current
          return attributes unless context

          attributes['posthogDistinctId'] = context.distinct_id if context.distinct_id
          attributes['sessionId'] = context.session_id if context.session_id

          properties = context.properties || {}
          REQUEST_ATTRIBUTE_NAMES.each do |key, attribute_name|
            value = properties[key] || properties[key.to_sym]
            attributes[attribute_name] = value if value
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
