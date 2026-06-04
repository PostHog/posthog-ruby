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
          MAPPING.fetch(severity, DEFAULT)
        end

        MAPPING = {
          ::Logger::DEBUG => [5, 'DEBUG'],
          ::Logger::INFO => [9, 'INFO'],
          ::Logger::WARN => [13, 'WARN'],
          ::Logger::ERROR => [17, 'ERROR'],
          ::Logger::FATAL => [21, 'FATAL'],
          ::Logger::UNKNOWN => [9, 'INFO']
        }.freeze

        DEFAULT = [9, 'INFO'].freeze
      end
    end
  end
end
