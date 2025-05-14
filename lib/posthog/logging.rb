require 'logger'

class PostHog
  # Wraps an existing logger and adds a prefix to all messages
  class PrefixedLogger
    def initialize(logger, prefix)
      @logger = logger
      @prefix = prefix
    end

    def debug(msg)
      @logger.debug("#{@prefix} #{msg}")
    end

    def info(msg)
      @logger.info("#{@prefix} #{msg}")
    end

    def warn(msg)
      @logger.warn("#{@prefix} #{msg}")
    end

    def error(msg)
      @logger.error("#{@prefix} #{msg}")
    end

    def level=(severity)
      @logger.level = severity
    end

    def level
      @logger.level
    end
  end

  module Logging
    class << self
      def logger
        return @logger if @logger

        base_logger =
          if defined?(Rails)
            Rails.logger
          else
            logger = Logger.new $stdout
            logger.progname = 'PostHog'
            logger.level = Logger::WARN
            logger
          end
        @logger = PrefixedLogger.new(base_logger, '[posthog-ruby]')
      end

      attr_writer :logger
    end

    def self.included(base)
      class << base
        def logger
          Logging.logger
        end
      end
    end

    def logger
      Logging.logger
    end
  end
end
