# frozen_string_literal: true

# Portions of this file are derived from getsentry/sentry-ruby
# Copyright (c) 2020 Sentry
# Licensed under the MIT License: https://github.com/getsentry/sentry-ruby/blob/master/LICENSE

module PostHog
  module Rails
    class Configuration
      # @return [Boolean] Whether to automatically capture exceptions from Rails. Defaults to false.
      attr_accessor :auto_capture_exceptions

      # @return [Boolean] Whether to capture exceptions that Rails rescues (e.g., with rescue_from). Defaults to false.
      attr_accessor :report_rescued_exceptions

      # @return [Boolean] Whether to automatically instrument ActiveJob. Defaults to false.
      attr_accessor :auto_instrument_active_job

      # @return [Array<String>] Exception class names to ignore in addition to the defaults.
      attr_accessor :excluded_exceptions

      # @return [Boolean] Whether to use PostHog tracing headers for request-scoped identity/session context.
      #   Defaults to true.
      attr_accessor :use_tracing_headers

      # @return [Boolean] Whether to capture the current user context in exceptions. Defaults to true.
      attr_accessor :capture_user_context

      # @return [Symbol] Method name to call on controller to get the current user. Defaults to :current_user.
      attr_accessor :current_user_method

      # @return [Symbol, nil] Method name to call on the user object to get distinct_id. When nil, tries:
      #   posthog_distinct_id, distinct_id, id, pk, uuid in order.
      attr_accessor :user_id_method

      # @return [PostHog::Rails::Configuration]
      def initialize
        @auto_capture_exceptions = false
        @report_rescued_exceptions = false
        @auto_instrument_active_job = false
        @excluded_exceptions = []
        @use_tracing_headers = true
        @capture_user_context = true
        @current_user_method = :current_user
        @user_id_method = nil
      end

      # Default exceptions that Rails apps typically don't want to track.
      #
      # @return [Array<String>]
      def default_excluded_exceptions
        [
          'AbstractController::ActionNotFound',
          'ActionController::BadRequest',
          'ActionController::InvalidAuthenticityToken',
          'ActionController::InvalidCrossOriginRequest',
          'ActionController::MethodNotAllowed',
          'ActionController::NotImplemented',
          'ActionController::ParameterMissing',
          'ActionController::RoutingError',
          'ActionController::UnknownFormat',
          'ActionController::UnknownHttpMethod',
          'ActionDispatch::Http::MimeNegotiation::InvalidType',
          'ActionDispatch::Http::Parameters::ParseError',
          'ActiveRecord::RecordNotFound',
          'ActiveRecord::RecordNotUnique'
        ]
      end

      # @param exception [Exception] The exception to check.
      # @return [Boolean] Whether the exception should be captured.
      def should_capture_exception?(exception)
        exception_name = exception.class.name
        !all_excluded_exceptions.include?(exception_name)
      end

      private

      def all_excluded_exceptions
        default_excluded_exceptions + excluded_exceptions
      end
    end
  end
end
