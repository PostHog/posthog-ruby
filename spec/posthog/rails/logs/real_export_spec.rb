# frozen_string_literal: true

require 'spec_helper'

$LOAD_PATH.unshift File.expand_path('../../../../posthog-rails/lib', __dir__)

require 'rails'
require 'posthog/rails'

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
RSpec.describe 'PostHog Logs real OTLP export' do
  before { skip 'Install the gemfiles/otel.gemfile bundle to run real OTLP integration' unless otel_available }

  let(:endpoint) { 'https://logs.example.test/i/v1/logs' }

  it 'exports structured notifications through Setup with identity, session and active span correlation' do
    previous_config = PostHog::Rails.config
    previous_client = PostHog.client
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails::Logs::Setup.reset
    PostHog.init(api_key: 'phc_test', host: 'https://logs.example.test', test_mode: true)
    PostHog::Rails::Logs::Setup.remember_client_options(api_key: 'phc_test', host: 'https://logs.example.test')
    config = PostHog::Rails.config
    config.logs_enabled = true
    config.logs_notifications = %i[action_controller active_record active_job action_mailer]
    config.logs_level = :debug
    request_body = nil
    stub_request(:post, endpoint).to_return do |request|
      request_body = request.headers['Content-Encoding'] == 'gzip' ? Zlib.gunzip(request.body) : request.body
      { status: 200, body: '' }
    end
    allow(OpenTelemetry).to receive(:handle_error).and_call_original
    PostHog::Rails::Logs::Setup.install
    %i[action_controller active_record active_job action_mailer].each do |component|
      ActiveSupport.run_load_hooks(component, Class.new)
    end
    symbol_filter = proc do |key, value|
      value.replace('[FILTERED]') if key == :secret && value.is_a?(String)
    end
    app = double('application', config: double('config', filter_parameters: [:password, symbol_filter]))
    allow(Rails).to receive(:application).and_return(app)
    span_context = OpenTelemetry::Trace::SpanContext.new(trace_id: ['1' * 32].pack('H*'),
                                                         span_id: ['2' * 16].pack('H*'))
    span = OpenTelemetry::Trace.non_recording_span(span_context)
    parameter_payload = { password: 'secret', secret: 'PRIVATE_EXPORT', visible: 'ok' }
    job = double('job', job_id: 'job-1', queue_name: 'default', executions: 1, priority: nil,
                        arguments: [parameter_payload])
    PostHog.const_get(:Internal)::Context.with_context(distinct_id: 'log-user', session_id: 'log-session') do
      OpenTelemetry::Trace.with_span(span) do
        ActiveSupport::Notifications.instrument('process_action.action_controller',
                                                controller: 'HomeController', action: 'index', status: 200,
                                                params: parameter_payload) { :ok }
        ActiveSupport::Notifications.instrument('sql.active_record', sql: "SELECT 'secret'", cached: false) { :ok }
        ActiveSupport::Notifications.instrument('perform.active_job', job: job) { :ok }
        ActiveSupport::Notifications.instrument('deliver.action_mailer', mailer: 'ReceiptMailer', to: ['secret']) { :ok }
      end
    end
    expect(PostHog::Rails::Logs::Setup.provider.force_flush).to eq(OpenTelemetry::SDK::Logs::Export::SUCCESS)
    payload = Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest.decode(request_body)
    exported = payload.resource_logs.flat_map do |resource|
      resource.scope_logs.flat_map do |scope|
        scope.log_records.to_a
      end
    end
    expect(exported.size).to eq(4)
    bodies = exported.map { |record| record.body.string_value }
    expect(bodies).to eq([
                           'Rails controller request completed', 'Rails SQL query completed',
                           'Rails job lifecycle event', 'Rails mailer lifecycle event'
                         ])
    exported.each do |record|
      attributes = record.attributes.to_h { |attribute| [attribute.key, attribute.value] }
      expect(attributes.fetch('posthogDistinctId').string_value).to eq('log-user')
      expect(attributes.fetch('sessionId').string_value).to eq('log-session')
      expect(record.trace_id.unpack1('H*')).to eq('1' * 32)
      expect(record.span_id.unpack1('H*')).to eq('2' * 16)
      expect(record.time_unix_nano).to be_positive
    end
    params = exported.first.attributes.find { |attribute| attribute.key == 'rails.params' }.value.string_value
    arguments = exported[2].attributes.find { |attribute| attribute.key == 'rails.job.arguments' }.value.string_value
    expected_params = { 'password' => '[FILTERED]', 'secret' => '[FILTERED]', 'visible' => 'ok' }
    expect(JSON.parse(params)).to eq(expected_params)
    expect(JSON.parse(arguments)).to eq([expected_params])
    expect(exported.to_s).not_to include('PRIVATE_EXPORT')
    expect(parameter_payload[:secret]).to eq('PRIVATE_EXPORT')
    expect(OpenTelemetry).not_to have_received(:handle_error)
  ensure
    PostHog::Rails::Logs::Setup.shutdown
    PostHog::Rails::Logs::Setup.reset
    PostHog.client&.shutdown
    PostHog.client = previous_client
    PostHog::Rails.config = previous_config
  end

  it 'encodes a record and POSTs it to the OTLP endpoint with the bearer token' do
    request_body = nil
    stub = stub_request(:post, endpoint).to_return do |request|
      request_body = request.headers['Content-Encoding'] == 'gzip' ? Zlib.gunzip(request.body) : request.body
      { status: 200, body: '' }
    end

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
    expect(stub).to have_been_requested.once
    payload = Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest.decode(request_body)
    scopes = payload.resource_logs.flat_map { |resource| resource.scope_logs.to_a }
    expect(scopes.map { |scope| scope.scope.name }).to eq(['posthog-rails-test'])
    records = scopes.flat_map { |scope| scope.log_records.to_a }
    expect(records.map { |record| record.body.string_value }).to eq(['real export smoke'])
    expect(records.map(&:severity_number)).to eq([:SEVERITY_NUMBER_INFO])
    expect(a_request(:post, endpoint).with(
             headers: {
               'Authorization' => 'Bearer phc_test',
               'Content-Type' => 'application/x-protobuf'
             }
           )).to have_been_made.once
  ensure
    provider&.shutdown(timeout: 1)
  end
end
