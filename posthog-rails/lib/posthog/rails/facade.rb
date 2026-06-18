# frozen_string_literal: true

module PostHog
  module Rails
    # Install the Rails singleton-style PostHog facade at load time so Rails app
    # initializers can call PostHog.init before Railtie initializers run.
    #
    # @api private
    # @return [void]
    def self.install_posthog_facade!
      return if @posthog_facade_installed

      PostHog.class_eval do
        class << self
          attr_accessor :client

          # Initialize the singleton PostHog client used by Rails delegators.
          #
          # @param options [Hash] Core {PostHog::Client} options.
          # @yieldparam config [PostHog::Rails::InitConfig] Block-based core SDK configuration.
          # @return [PostHog::Client]
          def init(options = {})
            # If block given, yield to configuration
            if block_given?
              config = PostHog::Rails::InitConfig.new(options)
              yield config
              options = config.to_client_options
            end

            # Let the PostHog Logs pipeline reuse the same api_key/host without
            # the core client exposing public readers.
            PostHog::Rails::Logs::Setup.remember_client_options(options) if defined?(PostHog::Rails::Logs::Setup)

            # Create the PostHog client. If a client already exists, shut it down
            # after replacement so repeated init calls do not leave background
            # resources from the previous instance running.
            previous_client = @client
            @client = PostHog::Client.new(options)
            begin
              previous_client&.shutdown
            rescue StandardError => e
              PostHog::Logging.logger.warn("Failed to shut down previous PostHog client: #{e.message}")
            end
            @client
          end

          # @return [Boolean] Whether {PostHog.init} has created a client.
          def initialized?
            !@client.nil?
          end

          # Fallback for any client methods not explicitly defined.
          #
          # @api private
          def method_missing(method_name, ...)
            ensure_initialized!

            if client.respond_to?(method_name)
              client.public_send(method_name, ...)
            else
              super
            end
          end

          # @api private
          def respond_to_missing?(method_name, include_private = false)
            ensure_initialized!
            client.respond_to?(method_name, include_private) || super
          end

          private

          def ensure_initialized!
            return if initialized?

            @client = PostHog::Client.new(api_key: nil, silence_disabled_client_error: true)
          end
        end
      end

      %i[
        capture
        capture_exception
        identify
        alias
        group_identify
        is_feature_enabled
        get_feature_flag
        get_all_flags
      ].each do |method_name|
        PostHog.define_singleton_method(method_name) do |*args, **kwargs, &block|
          ensure_initialized!
          client.public_send(method_name, *args, **kwargs, &block)
        end
      end

      @posthog_facade_installed = true
    end
  end
end
