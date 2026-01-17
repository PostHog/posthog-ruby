# frozen_string_literal: true

require 'posthog/rails/parameter_filter'

module PostHog
  module Rails
    # ActiveJob integration to capture exceptions from background jobs
    module ActiveJobExtensions
      include ParameterFilter

      def perform_now
        super
      rescue StandardError => e
        # Capture the exception with job context
        capture_job_exception(e)
        raise
      end

      private

      def capture_job_exception(exception)
        return unless PostHog::Rails.config&.auto_instrument_active_job

        # Build distinct_id from job arguments if possible
        distinct_id = extract_distinct_id_from_job

        properties = {
          '$exception_source' => 'active_job',
          '$job_class' => self.class.name,
          '$job_id' => job_id,
          '$queue_name' => queue_name,
          '$job_priority' => priority,
          '$job_executions' => executions
        }

        # Add serialized job arguments (be careful with sensitive data)
        properties['$job_arguments'] = sanitize_job_arguments(arguments) if arguments.present?

        PostHog.capture_exception(exception, distinct_id, properties)
      rescue StandardError => e
        # Don't let PostHog errors break job processing
        PostHog::Logging.logger.error("Failed to capture job exception: #{e.message}")
      end

      def extract_distinct_id_from_job
        # Try to find a user ID in job arguments
        arguments.each do |arg|
          if arg.respond_to?(:id)
            return arg.id
          elsif arg.is_a?(Hash) && arg['user_id']
            return arg['user_id']
          elsif arg.is_a?(Hash) && arg[:user_id]
            return arg[:user_id]
          end
        end

        nil # No user context found
      end

      def sanitize_job_arguments(args)
        # Convert arguments to a safe format
        args.map do |arg|
          case arg
          when String
            # Truncate long strings to prevent huge payloads
            arg.length > 100 ? "[FILTERED: #{arg.length} chars]" : arg
          when Integer, Float, TrueClass, FalseClass, NilClass
            arg
          when Hash
            # Use Rails' filter_parameters to filter sensitive data
            filter_sensitive_params(arg)
          when ActiveRecord::Base
            { class: arg.class.name, id: arg.id }
          else
            arg.class.name
          end
        end
      rescue StandardError
        ['<serialization error>']
      end
    end
  end
end
