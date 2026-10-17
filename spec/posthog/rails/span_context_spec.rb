# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'rails/railtie'
require 'action_dispatch'
require 'rack/mock'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'
require 'posthog/otel/context_span_processor'

otel_available =
  begin
    require 'opentelemetry-sdk'
    true
  rescue LoadError
    false
  end

logs_available =
  begin
    require 'opentelemetry-logs-sdk'
    true
  rescue LoadError
    false
  end

RSpec.describe 'Rails span context' do
  before { skip 'Install the gemfiles/otel.gemfile bundle to run span integration' unless otel_available }

  let(:context_class) { PostHog.const_get(:Internal).const_get(:Context) }
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:provider) do
    OpenTelemetry::SDK::Trace::TracerProvider.new.tap do |instance|
      instance.add_span_processor(PostHog::ContextSpanProcessor.new)
      instance.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    end
  end
  let(:tracer) { provider.tracer('posthog-rails-test') }
  let(:headers) do
    {
      'HTTP_X_POSTHOG_DISTINCT_ID' => 'browser-person',
      'HTTP_X_POSTHOG_SESSION_ID' => 'browser-session'
    }
  end

  around do |example|
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    example.run
  ensure
    PostHog::Rails.config = previous_config
  end

  after { provider.shutdown if otel_available && defined?(OpenTelemetry::SDK) }

  def request(headers = {}, &block)
    app = lambda do |_env|
      block.call
      [200, { 'content-type' => 'text/plain' }, ['ok']]
    end
    PostHog::Rails::RequestContext.new(app).call(Rack::MockRequest.env_for('/request', headers))
  end

  [false, true].each do |raises|
    it "stamps the existing request span and clears context after #{raises ? 'failure' : 'success'}" do
      tracer.in_span('request') do
        invoke = lambda do
          request(headers) { raise 'request failed' if raises }
        end
        raises ? expect(&invoke).to(raise_error('request failed')) : invoke.call
        expect(context_class.current).to be_nil
      end

      expect(exporter.finished_spans.first.attributes).to include(
        'posthogDistinctId' => 'browser-person',
        'sessionId' => 'browser-session'
      )
    end
  end

  [
    { 'posthogDistinctId' => 'application-person' },
    { 'sessionId' => 'application-session' },
    { 'posthogDistinctId' => 'application-person', 'sessionId' => 'application-session' }
  ].each do |attributes|
    it "preserves explicit attributes #{attributes.keys.inspect}" do
      tracer.in_span('request', attributes: attributes) do
        request(headers) { tracer.in_span('child', attributes: attributes) { nil } }
      end

      exporter.finished_spans.each do |span|
        expect(span.attributes).to include(
          { 'posthogDistinctId' => 'browser-person', 'sessionId' => 'browser-session' }.merge(attributes)
        )
      end
    end
  end

  [
    [{}, true],
    [{ 'HTTP_X_POSTHOG_SESSION_ID' => " \u0000\t ", 'HTTP_X_POSTHOG_DISTINCT_ID' => '' }, true],
    [{ 'HTTP_X_POSTHOG_SESSION_ID' => 'disabled', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'disabled' }, false]
  ].each do |input, enabled|
    it "omits missing, invalid, or disabled IDs #{[input, enabled].inspect}" do
      PostHog::Rails.config.use_tracing_headers = enabled
      tracer.in_span('request') { request(input) { tracer.in_span('child') { nil } } }

      exporter.finished_spans.each do |span|
        expect(span.attributes || {}).not_to have_key('posthogDistinctId')
        expect(span.attributes || {}).not_to have_key('sessionId')
      end
    end
  end

  it 'omits empty explicit context IDs' do
    context_class.with_context(distinct_id: '', session_id: '') do
      tracer.in_span('child') { nil }
    end

    expect(exporter.finished_spans.first.attributes || {}).to be_empty
  end

  it 'captures child context at start and keeps it after the request ends' do
    child = nil
    request(headers) do
      child = tracer.start_span('child')
      context_class.current.distinct_id.replace('changed-person')
      context_class.current.session_id.replace('changed-session')
    end
    request('HTTP_X_POSTHOG_DISTINCT_ID' => 'other-person') { child.finish }
    tracer.in_span('outside') { nil }

    spans = exporter.finished_spans.to_h { |span| [span.name, span] }
    expect(spans['child'].attributes).to include(
      'posthogDistinctId' => 'browser-person', 'sessionId' => 'browser-session'
    )
    expect(spans['outside'].attributes || {}).to be_empty
  end

  it 'keeps two concurrent request contexts separate' do
    started = Queue.new
    proceed = Queue.new
    threads = %w[first second].map do |name|
      Thread.new do
        tracer.in_span(name) do
          request('HTTP_X_POSTHOG_DISTINCT_ID' => name, 'HTTP_X_POSTHOG_SESSION_ID' => "session-#{name}") do
            started << true
            proceed.pop
            tracer.in_span("child-#{name}") { nil }
          end
          expect(context_class.current).to be_nil
        end
      end
    end
    2.times { started.pop }
    2.times { proceed << true }
    threads.each(&:value)

    exporter.finished_spans.each do |span|
      name = span.name.delete_prefix('child-')
      expect(span.attributes).to include('posthogDistinctId' => name, 'sessionId' => "session-#{name}")
    end
    expect(context_class.current).to be_nil
  end

  it 'keeps interleaved requests separate with Rails fiber isolation' do
    previous_isolation = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
    fibers = %w[first second].map do |name|
      Fiber.new do
        tracer.in_span(name) do
          request('HTTP_X_POSTHOG_DISTINCT_ID' => name) do
            Fiber.yield
            tracer.in_span("child-#{name}") { nil }
          end
          expect(context_class.current).to be_nil
        end
      end
    end
    fibers.each(&:resume)
    fibers.each(&:resume)

    exporter.finished_spans.each do |span|
      expect(span.attributes).to include('posthogDistinctId' => span.name.delete_prefix('child-'))
    end
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = previous_isolation
  end

  [false, true].each do |lookup_raises|
    it "preserves normal requests when span lookup #{lookup_raises ? 'fails' : 'is unavailable'}" do
      if lookup_raises
        allow(OpenTelemetry::Trace).to receive(:current_span).and_raise('tracing unavailable')
      else
        hide_const('OpenTelemetry')
      end
      expect(request(headers) { nil }.first).to eq(200)
      expect(context_class.current).to be_nil
    end
  end

  it 'leaves sampled-out request spans unchanged' do
    provider.sampler = OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF
    tracer.in_span('request') { |span| request(headers) { expect(span).not_to be_recording } }

    expect(exporter.finished_spans).to be_empty
  end

  it 'forwards logs with the same session, person, and active trace as the request span' do
    skip 'Install the gemfiles/otel.gemfile bundle to run log integration' unless logs_available

    logs_exporter = OpenTelemetry::SDK::Logs::Export::InMemoryLogRecordExporter.new
    logs_provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    logs_provider.add_log_record_processor(
      OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(logs_exporter)
    )
    appender = PostHog::Rails::Logs::Appender.new(logs_provider.logger(name: 'posthog-rails-test'))
    tracer.in_span('request') { request(headers) { appender.info('request processed') } }
    appender.info('outside request')

    span = exporter.finished_spans.first
    record, outside = logs_exporter.emitted_log_records
    expect(record.attributes).to include(span.attributes)
    expect(record.trace_id).to eq(span.trace_id)
    expect(record.span_id).to eq(span.span_id)
    expect(outside.attributes).not_to have_key('posthogDistinctId')
    expect(outside.attributes).not_to have_key('sessionId')
  ensure
    logs_provider&.shutdown
  end
end
