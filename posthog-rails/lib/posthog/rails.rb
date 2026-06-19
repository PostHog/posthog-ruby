# frozen_string_literal: true

require 'posthog/rails/version'
require 'posthog/rails/configuration'
require 'posthog/rails/tracing_headers'
require 'posthog/rails/request_metadata'
require 'posthog/rails/request_context'
require 'posthog/rails/capture_exceptions'
require 'posthog/rails/rescued_exception_interceptor'
require 'posthog/rails/active_job'
require 'posthog/rails/error_subscriber'
require 'posthog/rails/logs/severity'
require 'posthog/rails/logs/rate_limiter'
require 'posthog/rails/logs/appender'
require 'posthog/rails/logs/setup'
require 'posthog/rails/facade'
require 'posthog/rails/railtie'

module PostHog
  module Rails
    # Thread-local key for tracking web request context
    IN_WEB_REQUEST_KEY = :posthog_in_web_request

    class << self
      # @return [PostHog::Rails::Configuration] Rails integration configuration.
      def config
        @config ||= Configuration.new
      end

      # @param config [PostHog::Rails::Configuration] Rails integration configuration.
      attr_writer :config

      # Configure Rails integration options.
      #
      # @yieldparam config [PostHog::Rails::Configuration]
      # @return [void]
      def configure
        yield config if block_given?
      end

      # Mark that we're in a web request context
      # CaptureExceptions middleware will handle exception capture
      # @api private
      # @return [void]
      def enter_web_request
        Thread.current[IN_WEB_REQUEST_KEY] = true
      end

      # Clear web request context (called at end of request)
      # @api private
      # @return [void]
      def exit_web_request
        Thread.current[IN_WEB_REQUEST_KEY] = false
      end

      # Check if we're currently in a web request context
      # Used by ErrorSubscriber to avoid duplicate captures
      # @api private
      # @return [Boolean]
      def in_web_request?
        Thread.current[IN_WEB_REQUEST_KEY] == true
      end
    end
  end
end

PostHog::Rails.install_posthog_facade!
