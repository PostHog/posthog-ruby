# frozen_string_literal: true

# Portions of this file are derived from getsentry/sentry-ruby
# Copyright (c) 2020 Sentry
# Licensed under the MIT License: https://github.com/getsentry/sentry-ruby/blob/master/LICENSE

require 'posthog/exception_capture'

module PostHog
  module Rails
    class Configuration
      # Default cap on log records forwarded to PostHog Logs per minute.
      DEFAULT_LOGS_MAX_RECORDS_PER_MINUTE = 6_000

      # @return [Boolean] Whether to automatically capture exceptions from Rails. Defaults to false.
      attr_accessor :auto_capture_exceptions

      # @return [Boolean] Whether to capture exceptions that Rails rescues (e.g., with rescue_from). Defaults to false.
      attr_accessor :report_rescued_exceptions

      # @return [Boolean] Whether to automatically instrument ActiveJob. Defaults to false.
      attr_accessor :auto_instrument_active_job

      # @return [Boolean] Whether to report each Active Job retry failure. Requires auto_instrument_active_job.
      #   Defaults to false.
      attr_accessor :report_active_job_retries

      # @return [Array<String>] Exception class names to ignore in addition to the defaults. Subclasses are
      #   ignored too, and so is any exception whose cause chain contains a listed class.
      attr_accessor :excluded_exceptions

      # @return [Boolean] Whether to use PostHog tracing headers for request-scoped identity/session context.
      #   Defaults to true.
      attr_accessor :use_tracing_headers

      # @return [Boolean] Whether to capture the current user context in exceptions. Defaults to true.
      attr_accessor :capture_user_context

      # @return [Symbol] Method name to call on controller to get the current user. Defaults to :current_user.
      attr_accessor :current_user_method

      # @return [Proc, nil] Callable used to resolve the current user. When set, this takes precedence over
      #   current_user_method. The callable may accept the controller instance or no arguments.
      attr_accessor :current_user_resolver

      # @return [Symbol, nil] Method name to call on the user object to get distinct_id. When nil, tries:
      #   posthog_distinct_id, distinct_id, id, pk, uuid in order.
      attr_accessor :user_id_method

      # @return [Boolean] Master switch for forwarding logs to PostHog Logs over OTLP. Defaults to false.
      attr_accessor :logs_enabled

      # @return [Boolean] Whether to broadcast Rails.logger output into the PostHog Logs sink. Defaults to true
      #   (only takes effect when {#logs_enabled} is true).
      attr_accessor :logs_forward_rails_logger

      # @return [Array<Symbol>] Components whose notifications produce structured logs. Defaults to [].
      #   Supports :action_controller, :active_record, :active_job, and :action_mailer.
      #   Only takes effect when logs_enabled is true; components are not loaded automatically.
      attr_accessor :logs_notifications

      # @return [Integer, Symbol, nil] Minimum severity to forward to PostHog Logs. When nil, inherits the
      #   current Rails.logger level. Accepts a Logger severity constant (e.g. Logger::INFO) or symbol (:info).
      attr_accessor :logs_level

      # @return [Integer, String, nil] Maximum log records forwarded to PostHog Logs per minute, protecting
      #   the ingestion quota from runaway log volume. Defaults to 6000. Numeric strings (e.g. from ENV) are
      #   coerced. Set to nil, 0, or a negative value to disable the cap; an unparseable value falls back to
      #   the default with a warning.
      attr_accessor :logs_max_records_per_minute

      # @return [Proc, nil] Callback invoked with each log record hash (:timestamp, :severity, :body,
      #   :attributes — where :severity is a symbol such as :warn) before it is sent to PostHog Logs.
      #   Return a (possibly modified) hash to send, or nil to drop the record — useful for scrubbing
      #   PII. If the callback raises, the record is dropped. Defaults to nil.
      attr_accessor :logs_before_send

      # @return [PostHog::Rails::Configuration]
      def initialize
        @auto_capture_exceptions = false
        @report_rescued_exceptions = false
        @auto_instrument_active_job = false
        @report_active_job_retries = false
        @excluded_exceptions = []
        @use_tracing_headers = true
        @capture_user_context = true
        @current_user_method = :current_user
        @current_user_resolver = nil
        @user_id_method = nil
        @logs_enabled = false
        @logs_forward_rails_logger = true
        @logs_notifications = []
        @logs_level = nil
        @logs_max_records_per_minute = DEFAULT_LOGS_MAX_RECORDS_PER_MINUTE
        @logs_before_send = nil
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
        excluded = all_excluded_exceptions
        exception_chain(exception).none? do |error|
          error.class.ancestors.any? { |ancestor| excluded.include?(ancestor.name) }
        end
      end

      private

      def all_excluded_exceptions
        default_excluded_exceptions + excluded_exceptions
      end

      def exception_chain(exception)
        chain = []
        while exception.is_a?(Exception) && chain.size < ExceptionCapture::MAX_CHAINED_EXCEPTIONS
          chain << exception
          exception = exception.cause
        end
        chain
      end
    end
  end
end
