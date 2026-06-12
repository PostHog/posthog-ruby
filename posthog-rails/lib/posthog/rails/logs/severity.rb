# frozen_string_literal: true

require 'logger'

module PostHog
  module Rails
    module Logs
      # Maps Ruby `Logger` severities to OpenTelemetry log severity numbers and text.
      #
      # OpenTelemetry defines severity ranges (DEBUG=5-8, INFO=9-12, WARN=13-16,
      # ERROR=17-20, FATAL=21-24); we map each Ruby level to the base of its range.
      #
      # @api private
      module Severity
        module_function

        # @param severity [Integer, nil] A Ruby `Logger` severity constant.
        # @return [Array(Integer, String)] OpenTelemetry severity number and text.
        def for(severity)
          for_name(name_for(severity))
        end

        # @param severity [Integer, nil] A Ruby `Logger` severity constant.
        # @return [Symbol] The severity name (:debug, :info, :warn, :error, :fatal).
        def name_for(severity)
          NAMES.fetch(severity, :info)
        end

        # @param name [Symbol, String, nil] A severity name such as :warn.
        # @return [Array(Integer, String)] OpenTelemetry severity number and text;
        #   unrecognized names fall back to INFO.
        def for_name(name)
          OTEL.fetch(name.to_s.downcase.to_sym, OTEL[:info])
        end

        NAMES = {
          ::Logger::DEBUG => :debug,
          ::Logger::INFO => :info,
          ::Logger::WARN => :warn,
          ::Logger::ERROR => :error,
          ::Logger::FATAL => :fatal,
          ::Logger::UNKNOWN => :info
        }.freeze

        OTEL = {
          debug: [5, 'DEBUG'],
          info: [9, 'INFO'],
          warn: [13, 'WARN'],
          error: [17, 'ERROR'],
          fatal: [21, 'FATAL']
        }.freeze
      end
    end
  end
end
