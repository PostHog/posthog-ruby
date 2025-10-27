# frozen_string_literal: true

module PostHog
  module Rails
    class Railtie < ::Rails::Railtie
      # Add PostHog module methods for accessing Rails-specific client
      initializer 'posthog.set_configs' do |app|
        PostHog.class_eval do
          class << self
            attr_accessor :rails_config, :client

            # Initialize PostHog client with a block configuration
            def init(options = {}, &block)
              @rails_config ||= PostHog::Rails::Configuration.new

              # If block given, yield to configuration
              if block_given?
                config = PostHog::Rails::InitConfig.new(@rails_config, options)
                yield config
                options = config.to_client_options
              end

              # Create the PostHog client
              @client = PostHog::Client.new(options)
            end

            # Delegate common methods to the singleton client
            def capture(*args, **kwargs)
              ensure_initialized!
              client.capture(*args, **kwargs)
            end

            def capture_exception(*args, **kwargs)
              ensure_initialized!
              client.capture_exception(*args, **kwargs)
            end

            def identify(*args, **kwargs)
              ensure_initialized!
              client.identify(*args, **kwargs)
            end

            def alias(*args, **kwargs)
              ensure_initialized!
              client.alias(*args, **kwargs)
            end

            def group_identify(*args, **kwargs)
              ensure_initialized!
              client.group_identify(*args, **kwargs)
            end

            def is_feature_enabled(*args, **kwargs)
              ensure_initialized!
              client.is_feature_enabled(*args, **kwargs)
            end

            def get_feature_flag(*args, **kwargs)
              ensure_initialized!
              client.get_feature_flag(*args, **kwargs)
            end

            def get_all_flags(*args, **kwargs)
              ensure_initialized!
              client.get_all_flags(*args, **kwargs)
            end

            def initialized?
              !@client.nil?
            end

            private

            def ensure_initialized!
              unless initialized?
                raise 'PostHog is not initialized. Call PostHog.init in an initializer.'
              end
            end
          end
        end
      end

      # Insert middleware for exception capturing
      initializer 'posthog.insert_middlewares' do |app|
        # Insert after DebugExceptions to catch rescued exceptions
        app.config.middleware.insert_after(
          ActionDispatch::DebugExceptions,
          PostHog::Rails::RescuedExceptionInterceptor
        )

        # Insert after ShowExceptions to capture all exceptions
        app.config.middleware.insert_after(
          ActionDispatch::ShowExceptions,
          PostHog::Rails::CaptureExceptions
        )
      end

      # Hook into ActiveJob before classes are loaded
      initializer 'posthog.active_job', before: :eager_load! do
        ActiveSupport.on_load(:active_job) do
          # Prepend our module to ActiveJob::Base to wrap perform_now
          prepend PostHog::Rails::ActiveJobExtensions
        end
      end

      # After initialization, set up remaining integrations
      config.after_initialize do |app|
        next unless PostHog.initialized?

        # Register with Rails error reporter (Rails 7.0+)
        register_error_subscriber if rails_version_above_7?
      end

      # Ensure PostHog shuts down gracefully
      config.to_prepare do
        at_exit do
          PostHog.client&.shutdown if PostHog.initialized?
        end
      end

      private

      def self.register_error_subscriber
        return unless PostHog.rails_config&.auto_capture_exceptions

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
      attr_reader :rails_config

      def initialize(rails_config, base_options = {})
        @rails_config = rails_config
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

      # Rails-specific options
      def auto_capture_exceptions=(value)
        @rails_config.auto_capture_exceptions = value
      end

      def report_rescued_exceptions=(value)
        @rails_config.report_rescued_exceptions = value
      end

      def auto_instrument_active_job=(value)
        @rails_config.auto_instrument_active_job = value
      end

      def excluded_exceptions=(value)
        @rails_config.excluded_exceptions = value
      end

      def capture_user_context=(value)
        @rails_config.capture_user_context = value
      end

      def current_user_method=(value)
        @rails_config.current_user_method = value
      end

      def to_client_options
        @base_options
      end
    end
  end
end
