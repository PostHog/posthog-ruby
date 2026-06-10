# frozen_string_literal: true

require 'spec_helper'
require 'rails'

$LOAD_PATH.unshift File.expand_path('../../../../posthog-rails/lib', __dir__)

require 'posthog/rails'

RSpec.describe PostHog::Rails::Logs::Setup do
  around do |example|
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    described_class.reset!
    example.run
  ensure
    described_class.reset!
    PostHog::Rails.config = previous_config
  end

  describe '.install!' do
    context 'when the OpenTelemetry gems are missing' do
      before do
        allow(described_class).to receive(:require).and_wrap_original do |original, name, *rest|
          raise LoadError, "cannot load such file -- #{name}" if name.to_s.start_with?('opentelemetry')

          original.call(name, *rest)
        end
      end

      it 'no-ops and warns exactly once' do
        logger = instance_spy(Logger)
        PostHog::Logging.logger = logger

        expect(described_class.install!).to be_nil
        described_class.install! # idempotent; should not warn again

        expect(logger).to have_received(:warn).once
      end
    end

    context 'when no token can be resolved' do
      before do
        allow(described_class).to receive(:require_otel_gems).and_return(true)
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('POSTHOG_API_KEY', nil).and_return(nil)
      end

      it 'no-ops and warns about the missing token' do
        logger = instance_spy(Logger)
        PostHog::Logging.logger = logger

        expect(described_class.install!).to be_nil
        expect(logger).to have_received(:warn).once
      end
    end

    context 'when the OpenTelemetry gems are available' do
      let(:exporter_args) { {} }
      let(:otel_logger) { double('otel_logger') }
      let(:provider) { double('provider', add_log_record_processor: nil, logger: otel_logger) }

      before do
        allow(described_class).to receive(:require_otel_gems).and_return(true)

        resource_class = Class.new
        resource_class.define_singleton_method(:create) { |attrs| attrs }

        provider_double = provider
        provider_class = Class.new
        provider_class.define_singleton_method(:new) { |**| provider_double }

        captured = exporter_args
        exporter_class = Class.new
        exporter_class.define_singleton_method(:new) do |**kwargs|
          captured.merge!(kwargs)
          Object.new
        end

        processor_class = Class.new
        processor_class.define_singleton_method(:new) { |_exporter| Object.new }

        stub_const('OpenTelemetry::SDK::Resources::Resource', resource_class)
        stub_const('OpenTelemetry::SDK::Logs::LoggerProvider', provider_class)
        stub_const('OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor', processor_class)
        stub_const('OpenTelemetry::Exporter::OTLP::Logs::LogsExporter', exporter_class)
      end

      it 'derives the OTLP endpoint and bearer token from the remembered init options' do
        described_class.remember_client_options(api_key: 'phc_token', host: 'https://us.i.posthog.com')

        appender = described_class.install!

        expect(appender).to be_a(PostHog::Rails::Logs::Appender)
        expect(exporter_args[:endpoint]).to eq('https://us.i.posthog.com/i/v1/logs')
        expect(exporter_args[:headers]).to eq('Authorization' => 'Bearer phc_token')
      end

      it 'supports string-keyed init options and strips a trailing slash from the host' do
        described_class.remember_client_options('api_key' => 'phc_token', 'host' => 'https://eu.i.posthog.com/')

        described_class.install!

        expect(exporter_args[:endpoint]).to eq('https://eu.i.posthog.com/i/v1/logs')
        expect(exporter_args[:headers]).to eq('Authorization' => 'Bearer phc_token')
      end

      it 'falls back to ENV for token and host when no init options were captured' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('POSTHOG_API_KEY', nil).and_return('phc_env')
        allow(ENV).to receive(:fetch).with('POSTHOG_HOST', nil).and_return('https://eu.i.posthog.com')

        described_class.install!

        expect(exporter_args[:headers]).to eq('Authorization' => 'Bearer phc_env')
        expect(exporter_args[:endpoint]).to eq('https://eu.i.posthog.com/i/v1/logs')
      end

      it 'is idempotent and returns the same appender' do
        described_class.remember_client_options(api_key: 'phc_token', host: 'https://us.i.posthog.com')

        first = described_class.install!
        expect(described_class.install!).to be(first)
      end
    end
  end
end
