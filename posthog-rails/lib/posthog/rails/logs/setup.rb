# frozen_string_literal: true

require 'logger'
require 'posthog/logging'
require 'posthog/rails/logs/appender'

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
          def install!
            return @appender if @installed

            @installed = true
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

            @provider = build_provider(config, token)
            otel_logger = @provider.logger(name: 'posthog-rails', version: PostHog::VERSION)
            level = resolve_level(config.logs_level) || rails_logger_level
            @appender = Appender.new(otel_logger, level: level)
          rescue StandardError => e
            warn_once("Failed to initialize PostHog Logs: #{e.message}")
            nil
          end

          # Flush any buffered log records.
          #
          # @return [void]
          def force_flush
            @provider&.force_flush
          rescue StandardError => e
            logger.warn("Error flushing PostHog Logs: #{e.message}")
          end

          # Shut the pipeline down, flushing buffered records.
          #
          # @return [void]
          def shutdown!
            @provider&.shutdown
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

          def require_otel_gems
            require 'opentelemetry-sdk'
            require 'opentelemetry-logs-sdk'
            require 'opentelemetry/exporter/otlp_logs'
            true
          rescue LoadError => e
            warn_once(
              "PostHog Logs enabled but the OpenTelemetry gems are missing (#{e.message}). " \
              "Add 'opentelemetry-sdk', 'opentelemetry-logs-sdk', and " \
              "'opentelemetry-exporter-otlp-logs' to your Gemfile to enable log forwarding."
            )
            false
          end

          def build_provider(config, token)
            resource = OpenTelemetry::SDK::Resources::Resource.create(resource_attributes(config))
            provider = OpenTelemetry::SDK::Logs::LoggerProvider.new(resource: resource)
            exporter = OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new(
              endpoint: logs_endpoint(resolve_host),
              headers: { 'Authorization' => "Bearer #{token}" }
            )
            processor = OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(exporter)
            provider.add_log_record_processor(processor)
            provider
          end

          def resource_attributes(config)
            # service.version is intentionally omitted. Per OpenTelemetry semantic
            # conventions it is the deployed application's version, not this gem's.
            # The posthog-rails name/version travel with each record via the
            # instrumentation scope (see LoggerProvider#logger above). Users can
            # still set service.version through logs_resource_attributes.
            attrs = {
              'service.name' => service_name,
              'deployment.environment' => ::Rails.env.to_s
            }
            attrs.merge(stringify_keys(config.logs_resource_attributes || {}))
          end

          def service_name
            app = ::Rails.application
            return 'rails' unless app

            name = app.class.respond_to?(:module_parent_name) ? app.class.module_parent_name : nil
            name && !name.empty? ? name.to_s : 'rails'
          rescue StandardError
            'rails'
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

          def stringify_keys(hash)
            hash.transform_keys(&:to_s)
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
