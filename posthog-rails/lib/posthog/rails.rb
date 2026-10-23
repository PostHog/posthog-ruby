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
    end
  end
end

PostHog::Rails.install_posthog_facade!
