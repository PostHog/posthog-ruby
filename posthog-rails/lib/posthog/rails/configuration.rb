# frozen_string_literal: true

module PostHog
  module Rails
    class Configuration
      # Whether to automatically capture exceptions from Rails
      attr_accessor :auto_capture_exceptions

      # Whether to capture exceptions that Rails rescues (e.g., with rescue_from)
      attr_accessor :report_rescued_exceptions

      # Whether to automatically instrument ActiveJob
      attr_accessor :auto_instrument_active_job

      # List of exception classes to ignore (in addition to default)
      attr_accessor :excluded_exceptions

      # Whether to capture the current user context in exceptions
      attr_accessor :capture_user_context

      # Method name to call on controller to get user ID (default: :current_user)
      attr_accessor :current_user_method

      # Method name to call on user object to get distinct_id (default: auto-detect)
      # When nil, tries: posthog_distinct_id, distinct_id, id, pk, uuid in order
      attr_accessor :user_id_method

      def initialize
        @auto_capture_exceptions = false
        @report_rescued_exceptions = false
        @auto_instrument_active_job = false
        @excluded_exceptions = []
        @capture_user_context = true
        @current_user_method = :current_user
        @user_id_method = nil
      end

      # Default exceptions that Rails apps typically don't want to track
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
          'ActionDispatch::Http::Parameters::ParseError',
          'ActiveRecord::RecordNotFound',
          'ActiveRecord::RecordNotUnique'
        ]
      end

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
