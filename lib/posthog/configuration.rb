# frozen_string_literal: true

module PostHog
  # Configuration class for PostHog global settings
  class Configuration
    attr_accessor :api_key, :host, :personal_api_key
    attr_accessor :auto_capture_exceptions, :ignored_exceptions
    attr_accessor :default_distinct_id_strategy
    attr_accessor :max_queue_size, :test_mode
    attr_accessor :feature_flags_polling_interval, :feature_flag_request_timeout_seconds
    attr_accessor :before_send, :on_error
    attr_accessor :logger, :debug

    def initialize
      # Core settings
      @api_key = nil
      @host = 'https://app.posthog.com'
      @personal_api_key = nil
      
      # Error tracking settings
      @auto_capture_exceptions = false
      @ignored_exceptions = default_ignored_exceptions
      @default_distinct_id_strategy = :ip_address
      
      # Client settings
      @max_queue_size = 10_000
      @test_mode = false
      @feature_flags_polling_interval = 30
      @feature_flag_request_timeout_seconds = 3
      @before_send = nil
      @on_error = nil
      @logger = nil
      @debug = false
    end

    def api_key=(value)
      @api_key = value
      # Auto-enable exception capture when API key is set (unless explicitly disabled)
      @auto_capture_exceptions = true if value && !@auto_capture_exceptions_set_explicitly
    end

    def auto_capture_exceptions=(value)
      @auto_capture_exceptions = value
      @auto_capture_exceptions_set_explicitly = true
    end

    # Check if PostHog is configured enough to work
    def configured?
      !api_key.nil? && !api_key.empty?
    end

    # Validate configuration
    def validate!
      raise ArgumentError, 'PostHog API key is required' unless configured?
      
      if auto_capture_exceptions && ignored_exceptions
        unless ignored_exceptions.is_a?(Array)
          raise ArgumentError, 'ignored_exceptions must be an Array'
        end
        
        ignored_exceptions.each do |exception|
          unless [String, Class, Regexp].include?(exception.class)
            raise ArgumentError, 'ignored_exceptions must contain String, Class, or Regexp objects'
          end
        end
      end
      
      unless [:ip_address, :anonymous, :session].include?(default_distinct_id_strategy)
        raise ArgumentError, 'default_distinct_id_strategy must be :ip_address, :anonymous, or :session'
      end
    end

    private

    def default_ignored_exceptions
      [
        # Rails framework exceptions that are usually not actionable
        'ActionController::RoutingError',
        'ActionController::InvalidAuthenticityToken', 
        'ActionController::UnknownFormat',
        'ActionController::UnknownHttpMethod',
        'ActionDispatch::RemoteIp::IpSpoofAttackError',
        'ActionController::BadRequest',
        'ActionController::UnknownAction',
        
        # Rack exceptions
        'Rack::QueryParser::ParameterTypeError',
        'Rack::QueryParser::InvalidParameterError',
        
        # Common exceptions that are usually handled at application level
        'ActiveRecord::RecordNotFound',
        'NoMethodError',
        'NameError',
        'ArgumentError',
        
        # HTTP client errors (4xx) - usually not server errors
        /4\d{2}/,
        
        # System/Signal exceptions
        'SignalException',
        'Interrupt',
        'SystemExit'
      ]
    end
  end
  
  class << self
    attr_writer :configuration

    # Get the global configuration
    def configuration
      @configuration ||= Configuration.new
    end

    # Configure PostHog with a block
    #
    # @example
    #   PostHog.configure do |config|
    #     config.api_key = 'your_api_key'
    #     config.auto_capture_exceptions = true
    #     config.ignored_exceptions = ['ActionController::RoutingError']
    #   end
    def configure
      yield(configuration)
      configuration.validate!
      initialize_global_client
    end

    # Check if PostHog is configured
    def configured?
      configuration.configured?
    end

    # Global client instance (lazy-initialized)
    def client
      @client ||= initialize_global_client
    end

    # Convenience method for capturing exceptions via global client
    def capture_exception(exception_or_attrs, attrs = {})
      return unless configured?
      client.capture_exception(exception_or_attrs, attrs)
    end

    # Convenience method for capturing events via global client  
    def capture(attrs)
      return unless configured?
      client.capture(attrs)
    end

    # Convenience method for identifying users via global client
    def identify(attrs)
      return unless configured?
      client.identify(attrs)
    end

    # Reset the global configuration and client (useful for testing)
    def reset!
      @configuration = nil
      @client = nil
    end

    private

    def initialize_global_client
      return nil unless configured?
      
      @client = Client.new(
        api_key: configuration.api_key,
        host: configuration.host,
        personal_api_key: configuration.personal_api_key,
        max_queue_size: configuration.max_queue_size,
        test_mode: configuration.test_mode,
        feature_flags_polling_interval: configuration.feature_flags_polling_interval,
        feature_flag_request_timeout_seconds: configuration.feature_flag_request_timeout_seconds,
        before_send: configuration.before_send,
        on_error: configuration.on_error
      )
    end
  end
end