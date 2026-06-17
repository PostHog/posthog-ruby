# frozen_string_literal: true

require 'spec_helper'

$LOAD_PATH.unshift File.expand_path('../../../../posthog-rails/lib', __dir__)

require 'posthog/rails/logs/appender'

otel_available =
  begin
    require 'opentelemetry-sdk'
    require 'opentelemetry-logs-sdk'
    require 'opentelemetry/exporter/otlp_logs'
    true
  rescue LoadError
    false
  end

# Exercises the real OTLP encode + HTTP path end to end, which the fork-safety
# spec's fake exporter never touches. This is what guards against version
# incompatibility between opentelemetry-logs-sdk and the OTLP exporter: the
# exporter encodes LogRecordData#event_name, which only exists in logs-sdk
# >= 0.6.0, so an older pairing raises NoMethodError during encode — no HTTP
# request is ever made and the expectations below fail. (logs-sdk >= 0.6.0
# requires Ruby 3.3+, so this spec only runs where those gems are installed.)
RSpec.describe 'PostHog Logs real OTLP export', if: otel_available do
  let(:endpoint) { 'https://logs.example.test/i/v1/logs' }

  it 'encodes a record and POSTs it to the OTLP endpoint with the bearer token' do
    stub = stub_request(:post, endpoint).to_return(status: 200, body: '')

    provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    exporter = OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new(
      endpoint: endpoint,
      headers: { 'Authorization' => 'Bearer phc_test' }
    )
    provider.add_log_record_processor(
      OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(exporter)
    )
    appender = PostHog::Rails::Logs::Appender.new(
      provider.logger(name: 'posthog-rails-test'),
      level: Logger::INFO
    )

    appender.info('real export smoke')

    # force_flush exports synchronously; SUCCESS proves encode + transport ran.
    expect(provider.force_flush).to eq(OpenTelemetry::SDK::Logs::Export::SUCCESS)
    expect(stub).to have_been_requested
    expect(a_request(:post, endpoint).with(
             headers: {
               'Authorization' => 'Bearer phc_test',
               'Content-Type' => 'application/x-protobuf'
             }
           )).to have_been_made
  end
end
