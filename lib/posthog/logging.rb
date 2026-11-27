# frozen_string_literal: true

require 'logger'

module PostHog
  # Adds a prefix to all messages and writes them to the logger the block
  # returns, resolving it on every call.
  #
  # @api private
  class PrefixedLogger
    # @param prefix [String]
    # @yieldreturn [Logger, #debug, #info, #warn, #error]
    def initialize(prefix, &resolve_logger)
      @prefix = prefix
      @resolve_logger = resolve_logger
    end

    def debug(msg)
      @resolve_logger.call.debug("#{@prefix} #{msg}")
    end

    def info(msg)
      @resolve_logger.call.info("#{@prefix} #{msg}")
    end

    def warn(msg)
      @resolve_logger.call.warn("#{@prefix} #{msg}")
    end

    def error(msg)
      @resolve_logger.call.error("#{@prefix} #{msg}")
    end

    def level=(severity)
      @resolve_logger.call.level = severity
    end

    def level
      @resolve_logger.call.level
    end
  end

  module Logging
    class << self
      # @return [Logger, PostHog::PrefixedLogger] The logger used by the SDK.
      def logger
        @logger ||= begin
          stderr_logger = Logger.new $stderr
          stderr_logger.progname = 'PostHog'
          stderr_logger.level = Logger::WARN
          PrefixedLogger.new('[posthog-ruby]') { rails_logger || stderr_logger }
        end
      end

      # @param logger [Logger, #debug, #info, #warn, #error] Custom logger used by the SDK.
      attr_writer :logger

      private

      # Rails.logger is nil until the app boots, and gems such as
      # rails-html-sanitizer define ::Rails without it.
      def rails_logger
        ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
      end
    end

    def self.included(base)
      class << base
        def logger
          Logging.logger
        end
      end
    end

    # @return [Logger, PostHog::PrefixedLogger] The logger used by the SDK.
    def logger
      Logging.logger
    end
  end
end
