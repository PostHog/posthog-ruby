# frozen_string_literal: true

module PostHog
  module Rails
    class Railtie < ::Rails::Railtie
      # Add PostHog module methods for accessing Rails-specific client
      initializer 'posthog.set_configs' do |_app|
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
      end

      # Insert middleware for exception capturing
      initializer 'posthog.insert_middlewares' do |app|
        # Insert after DebugExceptions to catch rescued exceptions
        insert_middleware_after(
          app, ActionDispatch::DebugExceptions,
          PostHog::Rails::RescuedExceptionInterceptor
        )

        # Insert after ShowExceptions to capture all exceptions
        insert_middleware_after(
          app, ActionDispatch::ShowExceptions,
          PostHog::Rails::CaptureExceptions
        )
      end

      # After initialization, set up remaining integrations
      config.after_initialize do |_app|
        # Hook into ActiveJob only if enabled
        if PostHog::Rails.config&.auto_instrument_active_job
          ActiveSupport.on_load(:active_job) do
            prepend PostHog::Rails::ActiveJobExtensions
          end
        end

        next unless PostHog.initialized?

        # Register with Rails error reporter (Rails 7.0+)
        register_error_subscriber if rails_version_above_7?
      end

      # Ensure PostHog shuts down gracefully (register only once)
      config.after_initialize do
        next if @posthog_at_exit_registered

        @posthog_at_exit_registered = true
        at_exit { PostHog.client&.shutdown if PostHog.initialized? }
      end

      def insert_middleware_after(app, target, middleware)
        # During initialization, app.config.middleware is a MiddlewareStackProxy
        # which only supports recording operations (insert_after, use, etc.)
        # and does NOT support query methods like include?.
        app.config.middleware.insert_after(target, middleware)
      end

      def self.register_error_subscriber
        return unless PostHog::Rails.config&.auto_capture_exceptions

        subscriber = PostHog::Rails::ErrorSubscriber.new
        ::Rails.error.subscribe(subscriber)
      rescue StandardError => e
        PostHog::Logging.logger.warn("Failed to register error subscriber: #{e.message}")
        PostHog::Logging.logger.warn("Backtrace: #{e.backtrace&.first(5)&.join("\n")}")
      end

      def self.rails_version_above_7?
        ::Rails.version.to_f >= 7.0
      end
    end

    # Configuration wrapper for the init block
    class InitConfig
      def initialize(base_options = {})
        @base_options = base_options
      end

      # Core PostHog options
      def api_key=(value)
        @base_options[:api_key] = value
      end

      def personal_api_key=(value)
        @base_options[:personal_api_key] = value
      end

      def host=(value)
        @base_options[:host] = value
      end

      def max_queue_size=(value)
        @base_options[:max_queue_size] = value
      end

      def test_mode=(value)
        @base_options[:test_mode] = value
      end

      def on_error=(value)
        @base_options[:on_error] = value
      end

      def feature_flags_polling_interval=(value)
        @base_options[:feature_flags_polling_interval] = value
      end

      def feature_flag_request_timeout_seconds=(value)
        @base_options[:feature_flag_request_timeout_seconds] = value
      end

      def before_send=(value)
        @base_options[:before_send] = value
      end

      def to_client_options
        @base_options
      end
    end
  end
end
