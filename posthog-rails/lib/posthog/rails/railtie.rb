# frozen_string_literal: true

require 'posthog/rails/facade'

module PostHog
  module Rails
    class Railtie < ::Rails::Railtie
      # Keep the historical Railtie initializer name, but install the facade at
      # load time so application initializers can call PostHog.init.
      initializer 'posthog.set_configs' do |_app|
        PostHog::Rails.install_posthog_facade!
      end

      # Insert middleware for request context and exception capturing
      initializer 'posthog.insert_middlewares' do |app|
        # Wrap the Rails exception middleware so request context is active for
        # downstream handlers and exception capture.
        insert_middleware_before(
          app, ActionDispatch::ShowExceptions,
          PostHog::Rails::RequestContext
        )

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

      # Opt-in: forward logs to PostHog Logs over OTLP
      config.after_initialize do
        install_posthog_logs if PostHog::Rails.config&.logs_enabled
      end

      # Ensure PostHog shuts down gracefully (register only once)
      config.after_initialize do
        next if @posthog_at_exit_registered

        @posthog_at_exit_registered = true
        at_exit do
          PostHog::Rails::Logs::Setup.shutdown
          PostHog.client&.shutdown if PostHog.initialized?
        end
      end

      # @api private
      # @return [void]
      def insert_middleware_after(app, target, middleware)
        # During initialization, app.config.middleware is a MiddlewareStackProxy
        # which only supports recording operations (insert_after, use, etc.)
        # and does NOT support query methods like include?.
        app.config.middleware.insert_after(target, middleware)
      end

      # @api private
      # @return [void]
      def insert_middleware_before(app, target, middleware)
        # During initialization, app.config.middleware is a MiddlewareStackProxy
        # which only supports recording operations (insert_before, use, etc.)
        # and does NOT support query methods like include?.
        app.config.middleware.insert_before(target, middleware)
      end

      # Build the PostHog Logs pipeline and broadcast Rails.logger into it.
      #
      # @api private
      # @return [void]
      def self.install_posthog_logs
        unless PostHog.initialized?
          # logs_enabled is an explicit opt-in, so leave a breadcrumb instead
          # of silently skipping when PostHog.init never ran.
          PostHog::Logging.logger.warn(
            'PostHog Logs is enabled but PostHog.init has not been called; ' \
            'skipping log forwarding. Call PostHog.init in your initializer.'
          )
          return
        end

        # Mirror the core client: when it is disabled (missing/blank api_key)
        # every capture no-ops, so log forwarding should stay off too. The
        # client already logs its own missing-api_key error, so skip quietly.
        return unless PostHog.client.enabled?

        appender = PostHog::Rails::Logs::Setup.install
        return if appender.nil?

        broadcast_rails_logger(appender) if PostHog::Rails.config&.logs_forward_rails_logger
      rescue StandardError => e
        PostHog::Logging.logger.warn("Failed to set up PostHog Logs: #{e.message}")
      end

      # Attach the appender to Rails.logger, supporting both the Rails 7.1+
      # BroadcastLogger and the older ActiveSupport::Logger.broadcast mechanism.
      #
      # @api private
      # @return [void]
      def self.broadcast_rails_logger(appender)
        logger = ::Rails.logger
        return unless logger

        if logger.respond_to?(:broadcast_to)
          logger.broadcast_to(appender)
        elsif defined?(ActiveSupport::Logger) && ActiveSupport::Logger.respond_to?(:broadcast)
          logger.extend(ActiveSupport::Logger.broadcast(appender))
        else
          PostHog::Logging.logger.warn(
            'PostHog Logs could not broadcast Rails.logger; no compatible broadcast mechanism found.'
          )
        end
      end

      # @api private
      # @return [void]
      def self.register_error_subscriber
        return unless PostHog::Rails.config&.auto_capture_exceptions

        subscriber = PostHog::Rails::ErrorSubscriber.new
        ::Rails.error.subscribe(subscriber)
      rescue StandardError => e
        PostHog::Logging.logger.warn("Failed to register error subscriber: #{e.message}")
        PostHog::Logging.logger.warn("Backtrace: #{e.backtrace&.first(5)&.join("\n")}")
      end

      # @api private
      # @return [Boolean]
      def self.rails_version_above_7?
        ::Rails.version.to_f >= 7.0
      end
    end

    # Configuration wrapper for the init block
    class InitConfig
      # @param base_options [Hash] Initial core SDK options.
      def initialize(base_options = {})
        @base_options = base_options
      end

      # Core PostHog options
      #
      # @param value [String]
      # @return [String]
      def api_key=(value)
        @base_options[:api_key] = value
      end

      # @param value [String, nil]
      # @return [String, nil]
      def personal_api_key=(value)
        @base_options[:personal_api_key] = value
      end

      # @param value [String]
      # @return [String]
      def host=(value)
        @base_options[:host] = value
      end

      # @param value [Integer]
      # @return [Integer]
      def max_queue_size=(value)
        @base_options[:max_queue_size] = value
      end

      # @param value [Boolean]
      # @return [Boolean]
      def test_mode=(value)
        @base_options[:test_mode] = value
      end

      # @param value [Boolean]
      # @return [Boolean]
      def sync_mode=(value)
        @base_options[:sync_mode] = value
      end

      # @param value [Proc]
      # @return [Proc]
      def on_error=(value)
        @base_options[:on_error] = value
      end

      # @param value [Integer]
      # @return [Integer]
      def feature_flags_polling_interval=(value)
        @base_options[:feature_flags_polling_interval] = value
      end

      # @param value [Integer]
      # @return [Integer]
      def feature_flag_request_timeout_seconds=(value)
        @base_options[:feature_flag_request_timeout_seconds] = value
      end

      # @param value [Proc]
      # @return [Proc]
      def before_send=(value)
        @base_options[:before_send] = value
      end

      # @return [Hash] Core SDK options suitable for {PostHog::Client.new}.
      def to_client_options
        @base_options
      end
    end
  end
end
