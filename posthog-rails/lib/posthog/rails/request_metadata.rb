# frozen_string_literal: true

require 'posthog/rails/tracing_headers'

module PostHog
  module Rails
    # Internal helpers for extracting request metadata owned by RequestContext.
    module RequestMetadata
      module_function

      def extract(request)
        properties = {}
        add_property(properties, '$current_url', request_value(request, :url))
        request_method = request_value(request, :request_method) || request_value(request, :method)
        add_property(properties, '$request_method', request_method)
        add_property(properties, '$request_path', request_value(request, :path) || request_value(request, :path_info))
        add_property(properties, '$user_agent', TracingHeaders.extract_header(request, 'User-Agent'))
        add_property(properties, '$ip', client_ip(request))
        properties
      end

      def client_ip(request)
        trusted_ip = request_value(request, :remote_ip) || request_value(request, :ip)
        return trusted_ip if present?(trusted_ip)

        forwarded_for = TracingHeaders.extract_header(request, 'X-Forwarded-For')
        forwarded_ip = forwarded_for.split(',').first&.strip if forwarded_for
        return forwarded_ip if present?(forwarded_ip)

        env_value(request, 'REMOTE_ADDR')
      end
      private_class_method :client_ip

      def present?(value)
        !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
      end
      private_class_method :present?

      def add_property(properties, key, value)
        return if value.nil?

        serialized = value.to_s
        return if serialized.empty?

        properties[key] = serialized
      end
      private_class_method :add_property

      def request_value(request, method_name)
        return unless request.respond_to?(method_name)

        request.public_send(method_name)
      rescue StandardError
        nil
      end
      private_class_method :request_value

      def env_value(request, key)
        request.respond_to?(:get_header) ? request.get_header(key) : request.env[key]
      rescue StandardError
        nil
      end
      private_class_method :env_value
    end

    private_constant :RequestMetadata
  end
end
