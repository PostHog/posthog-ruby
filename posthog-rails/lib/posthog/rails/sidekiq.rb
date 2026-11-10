# frozen_string_literal: true

require 'posthog-rails'
require 'sidekiq'
require 'posthog/internal/context'

module PostHog
  module Rails
    module Sidekiq
      JOB_SCOPE_KEY = :posthog_sidekiq_job
      INSTALLATION_IVAR = :@posthog_sidekiq_integration
      DEFERRED_REPORT_IVAR = :@posthog_sidekiq_report
      Scope = Struct.new(:installation, :previous)

      # Install job error reporting on a Sidekiq server configuration.
      # @param config [::Sidekiq::Config]
      # @param error_reporting [Symbol] :all, :exhausted, or :dead.
      # @return [void]
      def self.install(config, error_reporting:)
        unless %i[all exhausted dead].include?(error_reporting)
          raise ArgumentError, 'error_reporting must be :all, :exhausted, or :dead'
        end

        if Gem::Version.new(::Rails.version) < Gem::Version.new('7.1') ||
           Gem::Version.new(::Sidekiq::VERSION) < Gem::Version.new('7.0.3')
          PostHog::Logging.logger.warn(
            'Sidekiq retry reporting requires Rails 7.1+ and Sidekiq 7.0.3+; leaving existing reporting unchanged.'
          )
          return
        end

        if (installation = config.instance_variable_get(INSTALLATION_IVAR))
          installation.error_reporting = error_reporting
          return
        end

        installation = Installation.new(error_reporting)
        config.server_middleware { |chain| chain.prepend(ServerMiddleware, installation) }
        config.capsules.each_value do |capsule|
          # Leave uncached chains lazy so they inherit later global middleware additions.
          capsule.instance_variable_get(:@server_chain)&.prepend(ServerMiddleware, installation)
        end
        config[:error_handlers] = config.error_handlers + [installation.method(:report_error)]
        config[:death_handlers] = config.death_handlers + [installation.method(:report_death)]
        config.instance_variable_set(INSTALLATION_IVAR, installation)
        nil
      end

      # @api private
      def self.in_job?
        scope = Thread.current[JOB_SCOPE_KEY]
        scope&.installation&.enabled?
      end

      # @api private
      def self.defer_capture?(error, distinct_id, properties)
        return false unless in_job?
        return true if error.instance_variable_defined?(DEFERRED_REPORT_IVAR)

        context = Internal::Context.current
        # Sidekiq invokes its handlers after the job's tracing middleware unwinds.
        properties = PostHog.client.send(:active_trace_properties).merge(properties)
        context_data = { distinct_id: context&.distinct_id, session_id: context&.session_id,
                         properties: context&.properties }
        error.instance_variable_set(DEFERRED_REPORT_IVAR, [distinct_id, properties, context_data]) unless error.frozen?
        true
      end

      # @api private
      def self.suppress_rails_report?(error, source)
        scope = Thread.current[JOB_SCOPE_KEY]
        installation = scope&.installation
        # Sidekiq sets its capsule before dispatch, including failures before middleware runs.
        installation ||= Thread.current[:sidekiq_capsule]&.config&.instance_variable_get(INSTALLATION_IVAR)
        return false unless installation&.enabled?

        source == 'job.sidekiq' || (source == 'application.active_job' && scope) ||
          (defined?(::Sidekiq::JobRetry::Handled) && error.is_a?(::Sidekiq::JobRetry::Handled))
      end

      class Installation
        attr_accessor :error_reporting

        def initialize(error_reporting)
          @error_reporting = error_reporting
        end

        def enabled?
          PostHog.initialized? && PostHog.client.enabled?
        end

        def with_job
          scope = Scope.new(self, Thread.current[JOB_SCOPE_KEY])
          Thread.current[JOB_SCOPE_KEY] = scope
          yield
        ensure
          Thread.current[JOB_SCOPE_KEY] = scope.previous
        end

        def report_error(error, context, _config = nil)
          return unless enabled? && error_reporting == :all
          return unless context[:job].is_a?(Hash)

          capture(error, 'sidekiq.error_handler')
        end

        def report_death(job, error)
          return unless enabled? && job.is_a?(Hash)
          return unless error_reporting == :exhausted ||
                        (error_reporting == :dead && job['retry'] && job['dead'] != false && !job['discarded_at'])

          capture(error, 'sidekiq.death_handler')
        end

        private

        def capture(error, source)
          return if excluded?(error)

          distinct_id, properties, context = error.instance_variable_get(DEFERRED_REPORT_IVAR)
          properties = (properties || {}).merge('$exception_source' => source, '$exception_level' => 'error')
          Internal::Context.with_context(context, fresh: true, owner: PostHog.client, enrich_current_span: false) do
            PostHog.capture_exception(
              error, distinct_id, properties, mechanism: { 'type' => 'task', 'handled' => false }
            )
          end
        rescue StandardError => e
          PostHog::Logging.logger.error("Failed to capture Sidekiq job error: #{e.class}")
        end

        def excluded?(error)
          seen = {}.compare_by_identity
          current = error
          while current && seen.size < PostHog::ExceptionCapture::MAX_CHAINED_EXCEPTIONS && !seen.key?(current)
            return true unless PostHog::Rails.config.should_capture_exception?(current)

            seen[current] = true
            current = current.cause
          end
          false
        end
      end

      class ServerMiddleware
        def initialize(installation)
          @installation = installation
        end

        def call(_worker, _job, _queue, &block)
          return yield unless @installation.enabled?

          @installation.with_job(&block)
        end
      end

      private_constant :JOB_SCOPE_KEY, :INSTALLATION_IVAR, :DEFERRED_REPORT_IVAR,
                       :Scope, :Installation, :ServerMiddleware
    end
  end
end
