# frozen_string_literal: true

require 'posthog/rails/configuration'
require 'posthog/rails/capture_exceptions'
require 'posthog/rails/rescued_exception_interceptor'
require 'posthog/rails/active_job'
require 'posthog/rails/error_subscriber'
require 'posthog/rails/railtie'

module PostHog
  module Rails
    VERSION = PostHog::VERSION

    class << self
      def config
        @config ||= Configuration.new
      end

      attr_writer :config
    end
  end
end
