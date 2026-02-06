# frozen_string_literal: true

require 'posthog/rails/configuration'
require 'posthog/rails/capture_exceptions'
require 'posthog/rails/rescued_exception_interceptor'
require 'posthog/rails/active_job'
require 'posthog/rails/error_subscriber'
require 'posthog/rails/railtie'

module PostHog
  module Rails
    VERSION = PostHog::VERSION

    # Thread-local key for tracking web request context
    IN_WEB_REQUEST_KEY = :posthog_in_web_request

    class << self
      def config
        @config ||= Configuration.new
      end

      attr_writer :config

      def configure
        yield config if block_given?
      end

      # Mark that we're in a web request context
      # CaptureExceptions middleware will handle exception capture
      def enter_web_request
        Thread.current[IN_WEB_REQUEST_KEY] = true
      end

      # Clear web request context (called at end of request)
      def exit_web_request
        Thread.current[IN_WEB_REQUEST_KEY] = false
      end

      # Check if we're currently in a web request context
      # Used by ErrorSubscriber to avoid duplicate captures
      def in_web_request?
        Thread.current[IN_WEB_REQUEST_KEY] == true
      end
    end
  end
end
