# frozen_string_literal: true

require 'posthog/rails/parameter_filter'
require 'posthog/internal/context'
require 'posthog/rails/tracing_headers'

module PostHog
  module Rails
    # ActiveJob integration to capture exceptions from background jobs
    module ActiveJobExtensions
      include ParameterFilter

      def self.prepended(base)
        base.extend(ClassMethods)
        base.around_perform :with_posthog_job_context, prepend: true if base.respond_to?(:around_perform)
      end

      module ClassMethods
        # DSL for defining how to extract distinct_id from job arguments.
        #
        # @param proc [Proc, nil] Callable that receives the job's perform arguments.
        # @yield The block receives the job's perform arguments.
        # @return [Proc, nil] The configured extractor.
        #
        # Example:
        #   class MyJob < ApplicationJob
        #     posthog_distinct_id ->(user, arg1, arg2) { user.id }
        #     def perform(user, arg1, arg2)
        #       # ...
        #     end
        #   end
        def posthog_distinct_id(proc = nil, &block)
          @posthog_distinct_id_proc = proc || block
        end

        # @return [Proc, nil] The configured distinct_id extractor.
        def posthog_distinct_id_proc
          @posthog_distinct_id_proc
        end
      end

      # @api private
      def enqueue(...)
        posthog_job_context if PostHog::Rails.config&.auto_instrument_active_job
        super
      end

      # @api private
      def serialize
        data = super
        return data unless PostHog::Rails.config&.auto_instrument_active_job

        data.merge('posthog_context' => posthog_job_context.dup)
      end

      # @api private
      def deserialize(data)
        super.tap { @posthog_job_context = copy_posthog_ids(data['posthog_context']) }
      end

      # @api private
      def rescue_with_handler(...)
        return super unless PostHog::Rails.config&.auto_instrument_active_job

        Internal::Context.with_context(
          @posthog_execution_context || posthog_job_context, fresh: true, enrich_current_span: false
        ) do
          enrich_posthog_job_span
          super
        end
      end

      def perform_now
        return super unless PostHog::Rails.config&.auto_instrument_active_job

        posthog_job_context
        @posthog_execution_context = nil
        Internal::Context.with_context({}, fresh: true, owner: PostHog.client, enrich_current_span: false) do
          super
        rescue StandardError => e
          # Capture the exception with job context
          Internal::Context.with_context(
            @posthog_execution_context || @posthog_job_context, fresh: true, enrich_current_span: false
          ) do
            enrich_posthog_job_span
            capture_job_exception(e)
          end
          raise
        end
      end

      private

      def copy_posthog_ids(data)
        data = {} unless data.is_a?(Hash)
        %w[distinct_id session_id].each_with_object({}) do |key, result|
          value = data[key]
          value = value.to_s if key == 'distinct_id' && (value.is_a?(Integer) || (value.is_a?(Float) && value.finite?))
          value = TracingHeaders.sanitize_header_value(value)
          result[key] = value.freeze if value
        end.freeze
      end

      def posthog_job_context
        @posthog_job_context ||= begin
          context = Internal::Context.current
          copy_posthog_ids('distinct_id' => context&.distinct_id, 'session_id' => context&.session_id)
        end
      end

      def with_posthog_job_context(&block)
        return yield unless PostHog::Rails.config&.auto_instrument_active_job

        distinct_id = posthog_job_distinct_id
        @posthog_execution_context = if distinct_id.nil?
                                       posthog_job_context
                                     else
                                       posthog_job_context.merge('distinct_id' => distinct_id).freeze
                                     end
        Internal::Context.with_context(@posthog_execution_context, fresh: true, enrich_current_span: false) do
          enrich_posthog_job_span
          block.call
        end
      end

      def enrich_posthog_job_span
        return unless defined?(::OpenTelemetry::Trace)

        span = ::OpenTelemetry::Trace.current_span
        return unless span.recording? && span.respond_to?(:attributes)

        attributes = span.attributes || {}
        return unless attributes['messaging.system'] == 'active_job' && attributes['messaging.message.id'] == job_id

        Internal::SpanContext.apply(span)
      rescue StandardError
        nil
      end

      def posthog_job_distinct_id
        extract_distinct_id_from_job
      rescue StandardError
        nil
      end

      def capture_job_exception(exception)
        return unless PostHog::Rails.config&.auto_instrument_active_job

        # Build distinct_id from job arguments if possible
        distinct_id = if @posthog_execution_context
                        @posthog_execution_context['distinct_id']
                      else
                        extract_distinct_id_from_job
                      end

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

        PostHog.capture_exception(
          exception,
          distinct_id,
          properties,
          mechanism: { 'type' => 'active_job', 'handled' => false }
        )
      rescue StandardError => e
        # Don't let PostHog errors break job processing
        PostHog::Logging.logger.error("Failed to capture job exception: #{e.message}")
      end

      def extract_distinct_id_from_job
        # First, check if the job class defines a custom extractor
        return self.class.posthog_distinct_id_proc.call(*arguments) if self.class.posthog_distinct_id_proc

        # Fallback: look for explicit user_id in hash arguments only
        arguments.each do |arg|
          if arg.is_a?(Hash) && arg['user_id']
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
          when defined?(ActiveRecord::Base) && ActiveRecord::Base
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
