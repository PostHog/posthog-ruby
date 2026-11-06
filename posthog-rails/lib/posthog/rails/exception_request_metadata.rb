# frozen_string_literal: true

require 'json'
require 'posthog/rails/parameter_filter'

module PostHog
  module Rails
    # Exception-only request data. Never added to the shared analytics/log context.
    # @api private
    module ExceptionRequestMetadata
      include ParameterFilter

      MAX_BODY_BYTES = 10_000

      private

      def exception_request_properties(request)
        properties = {}
        headers = allowlisted_headers(request)
        cookies = allowlisted_cookies(request)
        properties['$request_headers'] = filtered_metadata(headers) unless headers.empty?
        properties['$request_cookies'] = filtered_metadata(cookies) unless cookies.empty?
        if PostHog::Rails.config&.exception_request_body
          body = structured_request_body(request)
          if body
            properties['$request_body'] = if body.is_a?(Hash)
                                            filtered_metadata(body)
                                          else
                                            filtered_metadata('_json' => body)['_json']
                                          end
          end
        end
        properties
      end

      def allowlisted_headers(request)
        Array(PostHog::Rails.config&.exception_request_headers).first(100).each_with_object({}) do |name, result|
          next unless name.is_a?(String)

          name = name.downcase.tr('_', '-').sub(/\Ahttp-/, '')
          # Entire Cookie headers would bypass the cookie allowlist.
          next if %w[cookie set-cookie].include?(name)

          value = request.headers[name]
          result[name] = value if value.is_a?(String) && !value.empty?
        end
      end

      def allowlisted_cookies(request)
        names = Array(PostHog::Rails.config&.exception_request_cookies).first(100)
        return {} if names.empty?

        request.cookies.slice(*names)
      rescue StandardError
        {}
      end

      def structured_request_body(request)
        type = request.media_type
        unless type == 'application/json' || type&.end_with?('+json') || type == 'application/x-www-form-urlencoded'
          return
        end
        return if request.content_length > MAX_BODY_BYTES

        with_preserved_input(request) do |input|
          input.seek(0)
          body = input.read(MAX_BODY_BYTES + 1)
          next unless body.is_a?(String) && body.bytesize <= MAX_BODY_BYTES

          if type == 'application/x-www-form-urlencoded'
            Rack::Utils.parse_nested_query(body)
          else
            parsed = JSON.parse(body, max_nesting: ParameterFilter::MAX_DEPTH)
            parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)
          end
        end
      rescue StandardError
        nil
      end

      def exception_request_params(request)
        cached = request.get_header('action_dispatch.request.parameters')
        return cached if cached.is_a?(Hash)

        body = request.get_header('action_dispatch.request.request_parameters')
        body ||= structured_request_body(request)
        body = { '_json' => body } if body.is_a?(Array)
        # Match Rails precedence without invoking parsers that may log raw malformed bodies.
        (body || {}).merge(request.query_parameters).merge(request.path_parameters)
      rescue StandardError
        {}
      end

      def with_preserved_input(request)
        input = request.get_header('rack.input')
        return unless input.respond_to?(:pos) && input.respond_to?(:seek)

        position = input.pos
        input.seek(position) # Probe seekability before any read (pipes may implement seek).
        begin
          yield input
        ensure
          input.seek(position)
        end
      rescue StandardError
        nil
      end
    end

    private_constant :ExceptionRequestMetadata
  end
end
