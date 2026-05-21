# frozen_string_literal: true

module PostHog
  module Rails
    # Helpers for extracting and sanitizing PostHog tracing headers from Rack/Rails requests.
    #
    # @api private
    module TracingHeaders
      MAX_HEADER_VALUE_LENGTH = 1000
      CONTROL_CHARACTERS = /[[:cntrl:]]/

      module_function

      # @param value [Object]
      # @return [String, nil]
      def sanitize_header_value(value)
        return nil unless value.is_a?(String)

        sanitized = value.strip.gsub(CONTROL_CHARACTERS, '').strip
        return nil if sanitized.empty?

        sanitized[0, MAX_HEADER_VALUE_LENGTH]
      end

      # @param request_or_env [Object, Hash] Rack request, Rails request, or Rack env hash.
      # @param header_name [String]
      # @return [String, nil]
      def extract_header(request_or_env, header_name)
        candidates = header_candidates(header_name)

        candidates.each do |candidate|
          value = header_value(request_or_env, candidate)
          sanitized = sanitize_header_value(value)
          return sanitized if sanitized
        end

        env = request_env(request_or_env)
        return nil unless env.respond_to?(:each)

        target_names = candidates.map { |candidate| normalize_header_name(candidate) }
        env.each do |key, value|
          next unless target_names.include?(normalize_header_name(key))

          sanitized = sanitize_header_value(value)
          return sanitized if sanitized
        end

        nil
      end

      def header_candidates(header_name)
        canonical = header_name.to_s
        rack = "HTTP_#{canonical.upcase.tr('-', '_')}"
        [canonical, canonical.downcase, rack]
      end
      private_class_method :header_candidates

      def header_value(request_or_env, header_name)
        if request_or_env.respond_to?(:headers)
          value = request_or_env.headers[header_name]
          return value unless value.nil?
        end

        env = request_env(request_or_env)
        return nil unless env.respond_to?(:[])

        env[header_name]
      end
      private_class_method :header_value

      def request_env(request_or_env)
        request_or_env.respond_to?(:env) ? request_or_env.env : request_or_env
      end
      private_class_method :request_env

      def normalize_header_name(header_name)
        header_name.to_s.upcase.tr('-', '_')
      end
      private_class_method :normalize_header_name
    end

    private_constant :TracingHeaders
  end
end
