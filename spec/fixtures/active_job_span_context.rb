# frozen_string_literal: true

require 'rails'
require 'active_job'
require 'posthog'
require 'posthog/rails'
require 'posthog/otel/context_span_processor'
require 'opentelemetry-sdk'
require 'opentelemetry-instrumentation-active_job'

PostHog::Rails.config = PostHog::Rails::Configuration.new
PostHog::Rails.config.auto_instrument_active_job = true
PostHog::Logging.logger = Logger.new(File::NULL)
PostHog.client = PostHog::Client.new(api_key: 'phc_fixture', test_mode: true)
exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OpenTelemetry::SDK.configure do |config|
  config.add_span_processor(PostHog::ContextSpanProcessor.new)
  config.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
  config.use 'OpenTelemetry::Instrumentation::ActiveJob'
end

class SpanContextFixtureJob < ActiveJob::Base
  prepend PostHog::Rails::ActiveJobExtensions

  self.queue_adapter = :test
  self.logger = Logger.new(File::NULL)

  def perform
    OpenTelemetry.tracer_provider.tracer('job-fixture').in_span('child') do |span|
      span.set_attribute('job.performed', true)
    end
  end
end

context = PostHog.const_get(:Internal).const_get(:Context)
payloads = %w[first second].map do |identity|
  context.with_context(distinct_id: identity, session_id: "session-#{identity}") do
    SpanContextFixtureJob.perform_later
  end
  serialized_job = SpanContextFixtureJob.queue_adapter.enqueued_jobs.last.select { |key, _| key.is_a?(String) }
  JSON.parse(JSON.generate(serialized_job))
end
exporter.reset
tracer = OpenTelemetry.tracer_provider.tracer('job-fixture')
tracer.in_span('caller') { payloads.each { |payload| ActiveJob::Base.execute(payload) } }
spans = exporter.finished_spans
raise 'Caller span changed' unless (spans.find { |span| span.name == 'caller' }.attributes || {}).empty?

payloads.zip(%w[first second]).each do |payload, identity|
  job_span = spans.find { |span| span.attributes&.fetch('messaging.message.id', nil) == payload['job_id'] }
  raise 'Official job span missing' unless job_span
  raise 'Wrong instrumentation system' unless job_span.attributes['messaging.system'] == 'active_job'
  raise 'Job identity missing' unless job_span.attributes['posthogDistinctId'] == identity
  raise 'Job session missing' unless job_span.attributes['sessionId'] == "session-#{identity}"

  child = spans.find { |span| span.name == 'child' && span.parent_span_id == job_span.span_id }
  raise 'Child identity missing' unless child&.attributes&.fetch('posthogDistinctId', nil) == identity
end
raise 'Job scope leaked' unless context.current.nil?

OpenTelemetry.tracer_provider.shutdown
puts 'Official Active Job spans and children keep their IDs; caller and outer context stay unchanged'
