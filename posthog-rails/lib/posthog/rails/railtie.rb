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

      MISSING_MIDDLEWARE_MESSAGE = 'No such middleware to insert'
      MIDDLEWARE_FALLBACK_OPERATION = :posthog_insert_middleware_with_fallback

      module MiddlewareStackFallback
        def posthog_insert_middleware_with_fallback(location, target, middleware)
          PostHog::Rails::Railtie.instance.send(
            :insert_middleware_with_fallback,
            self,
            location,
            target,
            middleware
          )
        end

        private :posthog_insert_middleware_with_fallback
      end

      private_constant :MISSING_MIDDLEWARE_MESSAGE,
                       :MIDDLEWARE_FALLBACK_OPERATION,
                       :MiddlewareStackFallback

      # @api private
      # @return [void]
      def insert_middleware_after(app, target, middleware)
        insert_middleware(app.config.middleware, :after, target, middleware)
      end

      # @api private
      # @return [void]
      def insert_middleware_before(app, target, middleware)
        insert_middleware(app.config.middleware, :before, target, middleware)
      end

      # During initialization, app.config.middleware is usually a
      # Rails::Configuration::MiddlewareStackProxy. The proxy only records
      # operations, so missing-target errors happen later when Rails builds the
      # real ActionDispatch::MiddlewareStack. Add our own deferred operation so
      # we can fall back at build time instead of crashing or silently skipping.
      def insert_middleware(middleware_stack, location, target, middleware)
        if middleware_stack_proxy?(middleware_stack)
          append_middleware_operation(middleware_stack, location, target, middleware)
        else
          insert_middleware_with_fallback(middleware_stack, location, target, middleware)
        end
      end

      def middleware_stack_proxy?(middleware_stack)
        defined?(::Rails::Configuration::MiddlewareStackProxy) &&
          middleware_stack.instance_of?(::Rails::Configuration::MiddlewareStackProxy) &&
          middleware_stack.instance_variable_defined?(:@operations)
      end

      def append_middleware_operation(middleware_stack, location, target, middleware)
        operations = middleware_stack.instance_variable_get(:@operations)

        if callable_middleware_operations?(middleware_stack, operations)
          operations << lambda do |resolved_stack|
            insert_middleware_with_fallback(resolved_stack, location, target, middleware)
          end
        else
          ensure_middleware_stack_fallback_operation!
          operations << [MIDDLEWARE_FALLBACK_OPERATION, [location, target, middleware], nil]
        end
      end

      def callable_middleware_operations?(middleware_stack, operations)
        operation = operations.first || probe_middleware_operation(middleware_stack)

        operation.respond_to?(:call)
      end

      def probe_middleware_operation(middleware_stack)
        probe = middleware_stack.class.new
        probe.use(Object)
        probe.instance_variable_get(:@operations).first
      end

      def ensure_middleware_stack_fallback_operation!
        require 'action_dispatch/middleware/stack' unless defined?(::ActionDispatch::MiddlewareStack)
        return if ::ActionDispatch::MiddlewareStack < MiddlewareStackFallback

        ::ActionDispatch::MiddlewareStack.include(MiddlewareStackFallback)
      end

      def insert_middleware_with_fallback(middleware_stack, location, target, middleware)
        perform_middleware_insert(middleware_stack, location, target, middleware)
      rescue RuntimeError => e
        raise unless missing_middleware_error?(e)

        fallback_insert_middleware(middleware_stack, location, target, middleware)
      end

      def perform_middleware_insert(middleware_stack, location, target, middleware)
        if location == :after
          middleware_stack.insert_after(target, middleware)
        else
          middleware_stack.insert_before(target, middleware)
        end
      end

      def fallback_insert_middleware(middleware_stack, location, target, middleware)
        fallback_position = if location == :before && middleware_stack.respond_to?(:unshift)
                              middleware_stack.unshift(middleware)
                              'beginning'
                            else
                              middleware_stack.use(middleware)
                              'end'
                            end

        PostHog::Logging.logger.warn(
          "Could not find #{target.inspect} in the Rails middleware stack; " \
          "inserted #{middleware.inspect} at the #{fallback_position} " \
          'of the stack instead.'
        )
      end

      def missing_middleware_error?(error)
        error.message.start_with?(MISSING_MIDDLEWARE_MESSAGE)
      end

      private :insert_middleware,
              :middleware_stack_proxy?,
              :append_middleware_operation,
              :callable_middleware_operations?,
              :probe_middleware_operation,
              :ensure_middleware_stack_fallback_operation!,
              :insert_middleware_with_fallback,
              :perform_middleware_insert,
              :fallback_insert_middleware,
              :missing_middleware_error?

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

      # @param value [Boolean]
      # @return [Boolean]
      def compress_request=(value)
        @base_options[:compress_request] = value
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
