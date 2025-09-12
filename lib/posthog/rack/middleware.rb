# frozen_string_literal: true

begin
  require 'rack'
rescue LoadError
  # Rack not available, skip middleware definition
  return
end

module PostHog
  module Rack
    # Rack middleware for automatically capturing exceptions
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      rescue Exception => exception
        # Only capture if PostHog is configured and auto-capture is enabled
        capture_exception(exception, env) if should_capture?(exception)
        raise # Always re-raise the exception
      end

      private

      def should_capture?(exception)
        return false unless PostHog.configuration
        return false unless PostHog.configuration.auto_capture_exceptions
        return false if ignored_exception?(exception)
        
        true
      end

      def ignored_exception?(exception)
        return false unless PostHog.configuration.ignored_exceptions

        PostHog.configuration.ignored_exceptions.any? do |ignored_class|
          case ignored_class
          when String
            exception.class.name == ignored_class
          when Class
            exception.is_a?(ignored_class)
          when Regexp
            exception.class.name =~ ignored_class
          else
            false
          end
        end
      end

      def capture_exception(exception, env)
        request_data = extract_request_data(env)
        
        # Get user identification if available
        distinct_id = extract_distinct_id(env) || 'anonymous'

        PostHog.capture_exception(exception, {
          distinct_id: distinct_id,
          tags: {
            source: 'rack_middleware',
            http_method: request_data[:method],
            url: request_data[:url],
            user_agent: request_data[:user_agent]
          },
          extra: {
            request: request_data,
            environment: extract_environment_data(env)
          },
          handled: false  # Middleware captures are unhandled by default
        })
      rescue StandardError => e
        # Don't let error reporting break the application
        warn "PostHog middleware failed to capture exception: #{e.message}"
      end

      def extract_request_data(env)
        request = ::Rack::Request.new(env)
        
        {
          method: request.request_method,
          url: request.url,
          path: request.path,
          query_string: request.query_string,
          user_agent: request.user_agent,
          remote_ip: request.ip,
          content_type: request.content_type,
          content_length: request.content_length,
          headers: extract_headers(env),
          params: extract_params(request)
        }
      rescue StandardError => e
        # Fallback if request extraction fails
        {
          method: env['REQUEST_METHOD'],
          path: env['PATH_INFO'],
          query_string: env['QUERY_STRING'],
          user_agent: env['HTTP_USER_AGENT'],
          remote_ip: env['REMOTE_ADDR'],
          error: "Failed to extract request data: #{e.message}"
        }
      end

      def extract_headers(env)
        headers = {}
        env.each do |key, value|
          if key.start_with?('HTTP_')
            # Convert HTTP_USER_AGENT to User-Agent
            header_name = key[5..-1].split('_').map(&:capitalize).join('-')
            headers[header_name] = value
          end
        end
        
        # Include some important non-HTTP headers
        %w[CONTENT_TYPE CONTENT_LENGTH].each do |key|
          headers[key.split('_').map(&:capitalize).join('-')] = env[key] if env[key]
        end
        
        headers
      end

      def extract_params(request)
        return {} unless request.params
        
        # Remove sensitive parameters
        sensitive_keys = %w[password token secret key api_key access_token]
        params = request.params.dup
        
        params.each do |key, value|
          if sensitive_keys.any? { |sensitive| key.to_s.downcase.include?(sensitive) }
            params[key] = '[FILTERED]'
          end
        end
        
        params
      rescue StandardError
        {}
      end

      def extract_distinct_id(env)
        # Try multiple strategies to get user identification
        
        # 1. Check for PostHog user ID in session
        if env['rack.session']
          return env['rack.session']['posthog_user_id'] || env['rack.session']['user_id']
        end
        
        # 2. Check for Rails current_user (if in Rails context)
        if defined?(Rails) && env['action_controller.instance']
          controller = env['action_controller.instance']
          if controller.respond_to?(:current_user) && controller.current_user
            return controller.current_user.id.to_s rescue nil
          end
        end
        
        # 3. Check for cookies
        if env['HTTP_COOKIE']
          cookies = parse_cookies(env['HTTP_COOKIE'])
          return cookies['posthog_user_id'] || cookies['user_id']
        end
        
        # 4. Use IP address as fallback
        env['HTTP_X_FORWARDED_FOR']&.split(',')&.first&.strip || 
          env['HTTP_X_REAL_IP'] || 
          env['REMOTE_ADDR'] || 
          'unknown'
      end

      def parse_cookies(cookie_header)
        cookies = {}
        cookie_header.split(';').each do |cookie|
          key, value = cookie.strip.split('=', 2)
          cookies[key] = value if key && value
        end
        cookies
      rescue StandardError
        {}
      end

      def extract_environment_data(env)
        {
          rack_version: ::Rack::VERSION,
          ruby_version: RUBY_VERSION,
          ruby_platform: RUBY_PLATFORM,
          server_software: env['SERVER_SOFTWARE'],
          rack_url_scheme: env['rack.url_scheme'],
          script_name: env['SCRIPT_NAME'],
          server_name: env['SERVER_NAME'],
          server_port: env['SERVER_PORT']
        }
      end
    end
  end
end