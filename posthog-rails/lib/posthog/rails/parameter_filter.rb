# frozen_string_literal: true

module PostHog
  module Rails
    # Shared utility module for filtering sensitive parameters
    #
    # This module provides consistent parameter filtering across all PostHog Rails
    # components, leveraging Rails' built-in parameter filtering when available.
    # It automatically detects the correct Rails parameter filtering API based on
    # the Rails version.
    #
    # @example Usage in a class
    #   class MyClass
    #     include PostHog::Rails::ParameterFilter
    #
    #     def my_method(params)
    #       filtered = filter_sensitive_params(params)
    #       PostHog.capture(event: 'something', properties: filtered)
    #     end
    #   end
    module ParameterFilter
      EMPTY_HASH = {}.freeze

      if ::Rails.version.to_f >= 6.0
        def self.backend
          ActiveSupport::ParameterFilter
        end
      else
        def self.backend
          ActionDispatch::Http::ParameterFilter
        end
      end

      # Filter sensitive parameters from a hash, respecting Rails configuration.
      #
      # Uses Rails' configured filter_parameters (e.g., :password, :token, :api_key)
      # to automatically filter sensitive data that the Rails app has configured.
      #
      # @param params [Hash] The parameters to filter
      # @return [Hash] Filtered parameters with sensitive data masked
      def filter_sensitive_params(params)
        return EMPTY_HASH unless params.is_a?(Hash)

        filter_parameters = ::Rails.application.config.filter_parameters
        parameter_filter = ParameterFilter.backend.new(filter_parameters)

        parameter_filter.filter(params)
      end
    end
  end
end
