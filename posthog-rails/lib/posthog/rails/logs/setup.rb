# frozen_string_literal: true

require 'logger'
require 'posthog/logging'
require 'posthog/rails/configuration'
require 'posthog/rails/logs/appender'
require 'posthog/rails/logs/rate_limiter'

module PostHog
  module Rails
    module Logs
      # Bootstraps the OpenTelemetry logs pipeline that ships PostHog Logs.
      #
      # The OpenTelemetry gems are optional/soft dependencies. They are required
      # lazily here so that apps which do not enable logs (or run on a Ruby
      # version the logs SDK does not support) are unaffected.
      #
      # @api private
      module Setup
        # Bounds the at_exit flush. Without a timeout, the batch processor
        # joins its worker thread unbounded and the exporter retries each
        # batch with backoff — during an outage that can eat the whole
        # SIGTERM grace period and starve the events client of its flush.
        SHUTDOWN_TIMEOUT_SECONDS = 2

        class << self
          # @return [OpenTelemetry::SDK::Logs::LoggerProvider, nil]
          attr_reader :provider

          # @return [PostHog::Rails::Logs::Appender, nil]
          attr_reader :appender

          # Build the logs pipeline and return the broadcastable appender.
          #
          # Idempotent: subsequent calls return the previously built appender
          # (or nil if setup was skipped).
          #
          # @return [PostHog::Rails::Logs::Appender, nil]
          def install
            return @appender if @installed

            @installed = true

            # Respect the core client's test_mode: when it is on, the client
            # swaps in a NoopWorker so events never ship, and the logs pipeline
            # should likewise stay off so test suites don't emit real records.
            # Intentional state, so skip quietly (no warning).
            return nil if @client_test_mode

            return nil unless require_otel_gems

            config = PostHog::Rails.config
            token = resolve_token
            if token.nil?
              warn_once(
                'PostHog Logs enabled but no project token could be resolved ' \
                '(set config.api_key or POSTHOG_API_KEY); skipping.'
              )
              return nil
            end

            @provider = build_provider(token)
            otel_logger = @provider.logger(name: 'posthog-rails', version: PostHog::VERSION)
            level = resolve_level(config.logs_level) || rails_logger_level
            @appender = Appender.new(
              otel_logger,
              level: level,
              rate_limiter: build_rate_limiter(config),
              before_send: config.logs_before_send
            )
          rescue StandardError => e
            warn_once("Failed to initialize PostHog Logs: #{e.message}")
            nil
          end

          # Shut the pipeline down, flushing buffered records.
          #
          # @param timeout [Numeric] Max seconds to spend; see {SHUTDOWN_TIMEOUT_SECONDS}.
          # @return [void]
          def shutdown(timeout: SHUTDOWN_TIMEOUT_SECONDS)
            @provider&.shutdown(timeout: timeout)
          rescue StandardError => e
            logger.warn("Error shutting down PostHog Logs: #{e.message}")
          end

          # Remembers the api_key/host the PostHog client was initialized with
          # (called by PostHog.init) so the logs pipeline can reuse them without
          # the core client exposing public readers.
          #
          # @api private
          # @param options [Hash] The options passed to {PostHog::Client.new}.
          # @return [void]
          def remember_client_options(options)
            return unless options.is_a?(Hash)

            @client_api_key = options[:api_key] || options['api_key']
            @client_host = options[:host] || options['host']
            @client_test_mode = options[:test_mode] || options['test_mode']
          end

          # Resets memoized state. Intended for tests.
          #
          # @return [void]
          def reset!
            @installed = false
            @provider = nil
            @appender = nil
            @warned = false
            @client_api_key = nil
            @client_host = nil
            @client_test_mode = nil
          end

          private

          # The logs token is the same project token the core client uses
          # (i.e. config.api_key, captured by PostHog.init), falling back to
          # ENV['POSTHOG_API_KEY'].
          def resolve_token
            normalize(@client_api_key) || normalize(ENV.fetch('POSTHOG_API_KEY', nil))
          end

          # The logs host follows the core client's configured host (captured by
          # PostHog.init), falling back to ENV['POSTHOG_HOST'] and finally the
          # US cloud endpoint.
          def resolve_host
            normalize(@client_host) ||
              normalize(ENV.fetch('POSTHOG_HOST', nil)) ||
              'https://us.i.posthog.com'
          end

          # nil, 0, and negative values intentionally disable the cap. Numeric
          # strings (e.g. from ENV) are coerced — deliberately via Integer()
          # rather than to_i, since "abc".to_i == 0 would silently disable the
          # cap. Unparseable values warn and fall back to the default cap:
          # a misconfiguration should not switch the protection off.
          def build_rate_limiter(config)
            raw = config.logs_max_records_per_minute
            return nil if raw.nil?

            limit = Integer(raw, exception: false)
            if limit.nil?
              logger.warn(
                "logs_max_records_per_minute=#{raw.inspect} is not a number; using the default cap " \
                "of #{Configuration::DEFAULT_LOGS_MAX_RECORDS_PER_MINUTE} records/minute"
              )
              limit = Configuration::DEFAULT_LOGS_MAX_RECORDS_PER_MINUTE
            end
            return nil unless limit.positive?

            RateLimiter.new(limit)
          end

          def require_otel_gems
            require 'opentelemetry-sdk'
            require 'opentelemetry-logs-sdk'
            require 'opentelemetry/exporter/otlp_logs'
            true
          rescue LoadError => e
            warn_once(
              "PostHog Logs enabled but the OpenTelemetry gems are missing (#{e.message}). " \
              "Add 'opentelemetry-sdk', 'opentelemetry-logs-sdk', and " \
              "'opentelemetry-exporter-otlp-logs' (each with require: false) to your Gemfile " \
              'to enable log forwarding.'
            )
            false
          end

          def build_provider(token)
            resource = OpenTelemetry::SDK::Resources::Resource.create(resource_attributes)
            provider = OpenTelemetry::SDK::Logs::LoggerProvider.new(resource: resource)
            exporter = OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new(
              endpoint: logs_endpoint(resolve_host),
              headers: { 'Authorization' => "Bearer #{token}" }
            )
            processor = OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(exporter)
            provider.add_log_record_processor(processor)
            provider
          end

          def resource_attributes
            # service.version is intentionally omitted. Per OpenTelemetry semantic
            # conventions it is the deployed application's version, not this gem's.
            # The posthog-rails name/version travel with each record via the
            # instrumentation scope (see LoggerProvider#logger above).
            {
              'service.name' => service_name,
              'deployment.environment' => ::Rails.env.to_s
            }
          end

          def service_name
            app = ::Rails.application
            return 'unknown_service' unless app

            name = app.class.respond_to?(:module_parent_name) ? app.class.module_parent_name : nil
            name && !name.empty? ? name.to_s : 'unknown_service'
          rescue StandardError
            'unknown_service'
          end

          def logs_endpoint(host)
            base = (host || 'https://us.i.posthog.com').to_s.sub(%r{/+\z}, '')
            "#{base}/i/v1/logs"
          end

          def resolve_level(level)
            return nil if level.nil?
            return level if level.is_a?(Integer)

            ::Logger.const_get(level.to_s.upcase)
          rescue NameError
            warn_once(
              "Invalid logs_level #{level.inspect}; expected one of :debug, :info, :warn, " \
              ':error, :fatal, :unknown (or an Integer). Falling back to the Rails logger level.'
            )
            nil
          end

          def rails_logger_level
            ::Rails.logger&.level
          rescue StandardError
            nil
          end

          def normalize(value)
            return nil unless value.is_a?(String)

            stripped = value.strip
            stripped.empty? ? nil : stripped
          end

          def warn_once(message)
            return if @warned

            @warned = true
            logger.warn(message)
          end

          def logger
            PostHog::Logging.logger
          end
        end
      end
    end
  end
end
