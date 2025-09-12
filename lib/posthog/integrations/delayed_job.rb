# frozen_string_literal: true

if defined?(Delayed)
  module PostHog
    module Integrations
      module DelayedJob
        # DelayedJob plugin for automatic exception capture
        class Plugin < Delayed::Plugin
          callbacks do |lifecycle|
            lifecycle.around(:invoke_job) do |job, *args, &block|
              block.call(job, *args)
            rescue Exception => exception
              capture_exception(exception, job)
              raise
            end
          end

          private

          def self.capture_exception(exception, job)
            return unless PostHog.configured?
            return unless PostHog.configuration.auto_capture_exceptions

            # Extract distinct_id from job payload if possible
            distinct_id = extract_distinct_id_from_job(job) || 'system'

            PostHog.capture_exception(exception, {
              distinct_id: distinct_id,
              tags: {
                source: 'delayed_job',
                job_class: job.payload_object.class.name,
                queue: job.queue || 'default',
                job_id: job.id
              },
              extra: {
                job: filter_job_data(job),
                attempts: job.attempts,
                last_error: job.last_error&.truncate(1000),
                run_at: job.run_at&.iso8601,
                created_at: job.created_at&.iso8601,
                failed_at: job.failed_at&.iso8601,
                locked_at: job.locked_at&.iso8601,
                locked_by: job.locked_by
              },
              handled: false
            })
          rescue StandardError => e
            # Don't let error reporting break DelayedJob
            warn "PostHog DelayedJob plugin failed to capture exception: #{e.message}"
          end

          def self.extract_distinct_id_from_job(job)
            return nil unless job.payload_object

            payload = job.payload_object

            # Handle different job types
            case payload
            when Delayed::PerformableMethod
              # Method call job - check object and args
              extract_id_from_performable_method(payload)
            else
              # Custom job class - check if it responds to user_id or similar
              extract_id_from_job_object(payload)
            end
          end

          def self.extract_id_from_performable_method(payload)
            # Check the object being called
            if payload.object.respond_to?(:id)
              return payload.object.id.to_s
            end

            # Check method arguments
            if payload.args.present?
              # Look for user ID in arguments
              payload.args.each do |arg|
                if arg.is_a?(Integer) || (arg.is_a?(String) && arg.match?(/^\d+$/))
                  return arg.to_s
                elsif arg.respond_to?(:id)
                  return arg.id.to_s
                elsif arg.is_a?(Hash) && (arg[:user_id] || arg['user_id'])
                  return (arg[:user_id] || arg['user_id']).to_s
                end
              end
            end

            nil
          end

          def self.extract_id_from_job_object(job_object)
            # Check common methods for user identification
            %w[user_id distinct_id customer_id account_id].each do |method|
              if job_object.respond_to?(method)
                value = job_object.public_send(method)
                return value.to_s if value
              end
            end

            # Check if job object itself has an ID
            if job_object.respond_to?(:id)
              return job_object.id.to_s
            end

            nil
          end

          def self.filter_job_data(job)
            {
              id: job.id,
              queue: job.queue,
              handler_class: job.payload_object.class.name,
              attempts: job.attempts,
              priority: job.priority,
              run_at: job.run_at&.iso8601,
              created_at: job.created_at&.iso8601
            }
          rescue StandardError => e
            { error: "Failed to extract job data: #{e.message}" }
          end
        end

        # Auto-configure DelayedJob plugin when PostHog is configured
        def self.configure!
          return unless defined?(Delayed::Worker)
          return unless PostHog.configured?
          return unless PostHog.configuration.auto_capture_exceptions

          # Add the plugin to DelayedJob
          Delayed::Worker.plugins << Plugin
        end
      end
    end
  end

  # Auto-configure when DelayedJob is available
  if defined?(Delayed::Worker) && PostHog.configured?
    PostHog::Integrations::DelayedJob.configure!
  end
end