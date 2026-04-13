# frozen_string_literal: true

require 'posthog/rails/configuration'
require 'posthog/rails/capture_exceptions'
require 'posthog/rails/rescued_exception_interceptor'
require 'posthog/rails/active_job'
require 'posthog/rails/error_subscriber'
require 'posthog/rails/railtie'

# Extend the PostHog module with singleton methods for Rails integration.
# These are defined at load time (not in a Rails initializer) so they're
# available immediately when the gem is required — before any initializers run.
# This prevents NoMethodError when config/initializers/posthog.rb calls PostHog.init.
PostHog.class_eval do
  class << self
    attr_accessor :client

    # Methods explicitly delegated to the client
    DELEGATED_METHODS = %i[
      capture
      capture_exception
      identify
      alias
      group_identify
      is_feature_enabled
      get_feature_flag
      get_all_flags
    ].freeze

    # Initialize PostHog client with a block configuration
    def init(options = {})
      # If block given, yield to configuration
      if block_given?
        config = PostHog::Rails::InitConfig.new(options)
        yield config
        options = config.to_client_options
      end

      # Create the PostHog client
      @client = PostHog::Client.new(options)
    end

    # Define delegated methods using metaprogramming
    DELEGATED_METHODS.each do |method_name|
      define_method(method_name) do |*args, **kwargs, &block|
        ensure_initialized!
        client.public_send(method_name, *args, **kwargs, &block)
      end
    end

    def initialized?
      !@client.nil?
    end

    # Fallback for any client methods not explicitly defined
    # rubocop:disable Lint/RedundantSafeNavigation
    def method_missing(method_name, ...)
      if client&.respond_to?(method_name)
        ensure_initialized!
        client.public_send(method_name, ...)
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      client&.respond_to?(method_name) || super
    end
    # rubocop:enable Lint/RedundantSafeNavigation

    private

    def ensure_initialized!
      return if initialized?

      raise 'PostHog is not initialized. Call PostHog.init in an initializer.'
    end
  end
end

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
