# frozen_string_literal: true

if defined?(Sidekiq)
  module PostHog
    module Integrations
      module Sidekiq
        # Sidekiq server middleware for automatic exception capture
        class ServerMiddleware
          def call(worker, job, queue)
            yield
          rescue Exception => exception
            capture_exception(exception, worker, job, queue)
            raise
          end

          private

          def capture_exception(exception, worker, job, queue)
            return unless PostHog.configured?
            return unless PostHog.configuration.auto_capture_exceptions

            # Extract distinct_id from job arguments if possible
            distinct_id = extract_distinct_id_from_job(job) || 'system'

            PostHog.capture_exception(exception, {
              distinct_id: distinct_id,
              tags: {
                source: 'sidekiq',
                worker_class: worker.class.name,
                queue: queue,
                jid: job['jid']
              },
              extra: {
                job: filter_job_data(job),
                worker: worker.class.name,
                retry_count: job['retry_count'] || 0,
                failed_at: Time.now.utc.iso8601,
                enqueued_at: job['enqueued_at'] ? Time.at(job['enqueued_at']).utc.iso8601 : nil,
                created_at: job['created_at'] ? Time.at(job['created_at']).utc.iso8601 : nil
              },
              handled: false
            })
          rescue StandardError => e
            # Don't let error reporting break Sidekiq
            warn "PostHog Sidekiq middleware failed to capture exception: #{e.message}"
          end

          def extract_distinct_id_from_job(job)
            return nil unless job['args']

            # Try to find user ID in job arguments
            args = job['args']
            
            # Look for common patterns:
            # 1. First argument is user ID (common pattern)
            if args.first.is_a?(Integer) || (args.first.is_a?(String) && args.first.match?(/^\d+$/))
              return args.first.to_s
            end

            # 2. Hash argument with user_id key
            if args.first.is_a?(Hash)
              hash_arg = args.first
              return hash_arg['user_id']&.to_s || hash_arg[:user_id]&.to_s
            end

            # 3. ActiveRecord model as first argument (has ID)
            if args.first.is_a?(Hash) && args.first['_aj_globalid']
              # ActiveJob serialized model
              return extract_id_from_global_id(args.first['_aj_globalid'])
            end

            nil
          end

          def extract_id_from_global_id(global_id)
            # Parse GlobalID format: "gid://app/User/123"
            match = global_id.match(/gid:\/\/\w+\/\w+\/(\d+)/)
            match ? match[1] : nil
          rescue StandardError
            nil
          end

          def filter_job_data(job)
            # Remove potentially sensitive data but keep useful info
            filtered_job = job.dup
            
            # Keep these keys
            keep_keys = %w[jid class queue args retry_count failed_at enqueued_at created_at]
            filtered_job.select! { |k, _v| keep_keys.include?(k) }
            
            # Filter sensitive args
            if filtered_job['args']
              filtered_job['args'] = filter_sensitive_args(filtered_job['args'])
            end

            filtered_job
          end

          def filter_sensitive_args(args)
            return args unless args.is_a?(Array)

            args.map do |arg|
              case arg
              when Hash
                filter_sensitive_hash(arg)
              when String
                # Don't filter strings that look like tokens/passwords completely,
                # just truncate them to show pattern
                if looks_sensitive?(arg)
                  arg.length > 10 ? "#{arg[0..2]}***#{arg[-2..-1]}" : "[FILTERED]"
                else
                  arg
                end
              else
                arg
              end
            end
          end

          def filter_sensitive_hash(hash)
            sensitive_keys = %w[password token secret key api_key access_token auth_token
                              private_key public_key certificate]
            
            filtered_hash = hash.dup
            filtered_hash.each do |key, value|
              if sensitive_keys.any? { |sensitive| key.to_s.downcase.include?(sensitive) }
                filtered_hash[key] = '[FILTERED]'
              end
            end
            filtered_hash
          end

          def looks_sensitive?(string)
            return false unless string.is_a?(String)
            return false if string.length < 8

            # Look for patterns that might be tokens or passwords
            patterns = [
              /^[A-Za-z0-9+\/]{20,}={0,2}$/, # Base64
              /^[a-f0-9]{32,}$/i,             # Hex
              /^[A-Za-z0-9_-]{20,}$/          # URL-safe tokens
            ]

            patterns.any? { |pattern| string.match?(pattern) }
          end
        end

        # Sidekiq client middleware for capturing client-side errors
        class ClientMiddleware
          def call(worker_class, job, queue, redis_pool)
            yield
          rescue Exception => exception
            capture_client_exception(exception, worker_class, job, queue)
            raise
          end

          private

          def capture_client_exception(exception, worker_class, job, queue)
            return unless PostHog.configured?
            return unless PostHog.configuration.auto_capture_exceptions

            PostHog.capture_exception(exception, {
              distinct_id: 'system',
              tags: {
                source: 'sidekiq_client',
                worker_class: worker_class.to_s,
                queue: queue,
                jid: job['jid']
              },
              extra: {
                job: job,
                operation: 'enqueue'
              },
              handled: false
            })
          rescue StandardError => e
            warn "PostHog Sidekiq client middleware failed to capture exception: #{e.message}"
          end
        end

        # Auto-configure Sidekiq middleware when PostHog is configured
        def self.configure!
          return unless defined?(::Sidekiq)
          return unless PostHog.configured?
          return unless PostHog.configuration.auto_capture_exceptions

          # Add server middleware
          ::Sidekiq.configure_server do |config|
            config.server_middleware do |chain|
              chain.add ServerMiddleware
            end
          end

          # Add client middleware  
          ::Sidekiq.configure_client do |config|
            config.client_middleware do |chain|
              chain.add ClientMiddleware
            end
          end

          ::Sidekiq.configure_server do |config|
            config.client_middleware do |chain|
              chain.add ClientMiddleware
            end
          end
        end
      end
    end
  end

  # Auto-configure when Sidekiq is available
  if defined?(::Sidekiq) && PostHog.configured?
    PostHog::Integrations::Sidekiq.configure!
  end
end