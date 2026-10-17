# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'rails/railtie'
require 'active_job'
require 'open3'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'

RSpec.describe 'Active Job context' do
  let(:context_class) { PostHog.const_get(:Internal).const_get(:Context) }
  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }
  let(:observations) { [] }
  let(:exception_contexts) { [] }
  let(:job_class) do
    stub_const('PostHogContextTestJob', Class.new(ActiveJob::Base) do
      prepend PostHog::Rails::ActiveJobExtensions

      class_attribute :observer

      def perform(mode = 'success')
        self.class.observer.call(self)
        raise 'job failed' if mode == 'failure'
      end
    end)
    PostHogContextTestJob.queue_adapter = :test
    PostHogContextTestJob.logger = Logger.new(File::NULL)
    PostHogContextTestJob.observer = lambda do |job|
      current = context_class.current
      observations << [current&.distinct_id, current&.session_id, current&.properties]
      client.capture(event: 'job_ran')
      raise 'retry job' if job.arguments.first == 'retry' && job.executions == 1
    end
    PostHogContextTestJob
  end

  around do |example|
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails.config.auto_instrument_active_job = true
    example.run
  ensure
    PostHog::Rails.config = previous_config
    client.shutdown
  end

  before do
    allow(PostHog).to receive(:capture_exception) do
      current = context_class.current
      exception_contexts << [current&.distinct_id, current&.session_id]
    end
  end

  def snapshot_job(mode = 'success')
    context_class.with_context(distinct_id: 'browser-person', session_id: 'browser-session',
                               properties: { 'request_only' => 'excluded' }) do
      job_class.perform_later(mode)
    end
    JSON.parse(JSON.generate(job_class.queue_adapter.enqueued_jobs.last))
  end

  [false, true].each do |fails|
    it "restores enqueued IDs and clears worker scope after #{fails ? 'failure' : 'success'}" do
      payload = snapshot_job(fails ? 'failure' : 'success')
      context_class.with_context(distinct_id: 'worker-person', session_id: 'worker-session') do
        outer = context_class.current
        invoke = -> { ActiveJob::Base.execute(payload) }
        fails ? expect(&invoke).to(raise_error('job failed')) : invoke.call
        expect(context_class.current).to equal(outer)
      end
      expect(observations).to eq([['browser-person', 'browser-session', { '$session_id' => 'browser-session' }]])
      event = client.dequeue_last_message
      expect(event[:distinct_id]).to eq('browser-person')
      expect(event[:properties]['$session_id']).to eq('browser-session')
      expect(event[:properties]).not_to have_key('request_only')
      expect(context_class.current).to be_nil
      expect(PostHog).to have_received(:capture_exception).exactly(fails ? 1 : 0).times
      expect(exception_contexts).to eq(fails ? [%w[browser-person browser-session]] : [])
    end
  end

  it 'copies the enqueue snapshot and excludes request properties from the serialized payload' do
    person = +'browser-person'
    session = +'browser-session'
    job = nil
    context_class.with_context(distinct_id: person, session_id: session, properties: { 'private' => 'excluded' }) do
      job = job_class.perform_later
      person.replace('changed-person')
      session.replace('changed-session')
    end
    payload = JSON.parse(JSON.generate(job.serialize))
    expect(payload['posthog_context']).to eq('distinct_id' => 'browser-person', 'session_id' => 'browser-session')
    ActiveJob::Base.execute(payload)
    expect(observations.first.first(2)).to eq(%w[browser-person browser-session])
  end

  it 'takes its snapshot at enqueue before an adapter serializes the job later' do
    stub_const('DeferredContextTestAdapter', Class.new(ActiveJob::QueueAdapters::TestAdapter) do
      attr_reader :job

      def enqueue(job)
        @job = job
      end
    end)
    adapter = DeferredContextTestAdapter.new
    job_class.queue_adapter = adapter
    context_class.with_context(distinct_id: 'enqueue-person', session_id: 'enqueue-session') do
      job_class.perform_later
    end
    context_class.with_context(distinct_id: 'later-person', session_id: 'later-session') do
      payload = JSON.parse(JSON.generate(adapter.job.serialize))
      ActiveJob::Base.execute(payload)
    end
    expect(observations.first.first(2)).to eq(%w[enqueue-person enqueue-session])
  end

  [nil, {}, { 'session_id' => 12, 'distinct_id' => [] }].each do |saved|
    it "clears stale worker identity for a missing or invalid payload #{saved.inspect}" do
      payload = job_class.new.serialize
      saved.nil? ? payload.delete('posthog_context') : payload['posthog_context'] = saved
      context_class.with_context(distinct_id: 'stale-person', session_id: 'stale-session') do
        ActiveJob::Base.execute(payload)
      end
      expect(observations.first.first(2)).to eq([nil, nil])
    end
  end

  it 'uses caller context for direct perform_now and restores it' do
    context_class.with_context(distinct_id: 'direct-person', session_id: 'direct-session') do
      outer = context_class.current
      job_class.perform_now
      expect(context_class.current).to equal(outer)
    end
    expect(observations.first.first(2)).to eq(%w[direct-person direct-session])
  end

  it 'uses the explicit job distinct ID extractor after argument deserialization' do
    job_class.posthog_distinct_id { |data| data.fetch('user_id') }
    payload = nil
    context_class.with_context(distinct_id: 'browser-person', session_id: 'browser-session') do
      job_class.perform_later('user_id' => 'application-person')
      payload = JSON.parse(JSON.generate(job_class.queue_adapter.enqueued_jobs.last))
    end
    ActiveJob::Base.execute(payload)
    expect(observations.first.first(2)).to eq(%w[application-person browser-session])
  end

  it 'keeps saved identity on handled retries and captures only the final unhandled exception' do
    job_class.retry_on RuntimeError, wait: 0, attempts: 2
    payload = snapshot_job('retry')
    ActiveJob::Base.execute(payload)
    expect(PostHog).not_to have_received(:capture_exception)
    retry_payload = JSON.parse(JSON.generate(job_class.queue_adapter.enqueued_jobs.last))
    context_class.with_context(distinct_id: 'unrelated-person', session_id: 'unrelated-session') do
      ActiveJob::Base.execute(retry_payload)
    end
    expect(observations.map { |row| row.first(2) }).to eq([%w[browser-person browser-session]] * 2)
    expect(PostHog).not_to have_received(:capture_exception)
  end

  [false, true].each do |discard|
    it "captures only unhandled terminal errors, discard=#{discard}" do
      job_class.retry_on RuntimeError, wait: 0, attempts: 1
      job_class.discard_on RuntimeError if discard
      invoke = -> { ActiveJob::Base.execute(snapshot_job('failure')) }
      discard ? invoke.call : expect(&invoke).to(raise_error('job failed'))
      expect(PostHog).to have_received(:capture_exception).exactly(discard ? 0 : 1).times
    end
  end

  it 'supports bulk enqueue through the adapter serializer' do
    jobs = [job_class.new, job_class.new]
    context_class.with_context(distinct_id: 'bulk-person', session_id: 'bulk-session') do
      ActiveJob.perform_all_later(jobs)
    end
    job_class.queue_adapter.enqueued_jobs.each do |payload|
      ActiveJob::Base.execute(JSON.parse(JSON.generate(payload)))
    end
    expect(observations.map { |row| row.first(2) }).to eq([%w[bulk-person bulk-session]] * 2)
  end

  it 'captures deserialization errors with saved IDs and restores the worker context' do
    payload = snapshot_job
    payload['arguments'] = [{ '_aj_serialized' => 'MissingJobArgumentSerializer' }]
    context_class.with_context(distinct_id: 'worker-person', session_id: 'worker-session') do
      outer = context_class.current
      expect { ActiveJob::Base.execute(payload) }.to raise_error(ActiveJob::DeserializationError)
      expect(context_class.current).to equal(outer)
    end
    expect(observations).to be_empty
    expect(exception_contexts).to eq([%w[browser-person browser-session]])
  end

  it 'keeps concurrent workers and a later empty job separate' do
    payloads = %w[first second].map do |person|
      context_class.with_context(distinct_id: person, session_id: "session-#{person}") do
        job_class.perform_later
      end
      JSON.parse(JSON.generate(job_class.queue_adapter.enqueued_jobs.last))
    end
    started = Queue.new
    proceed = Queue.new
    original_observer = job_class.observer
    job_class.observer = lambda do |job|
      started << true
      proceed.pop
      original_observer.call(job)
    end
    threads = payloads.map do |payload|
      Thread.new do
        ActiveJob::Base.execute(payload)
        expect(context_class.current).to be_nil
      end
    end
    2.times { started.pop }
    2.times { proceed << true }
    threads.each(&:value)
    job_class.observer = original_observer
    ActiveJob::Base.execute(job_class.new.serialize)
    expect(observations.map { |row| row.first(2) }).to contain_exactly(
      %w[first session-first], %w[second session-second], [nil, nil]
    )
  end

  it 'keeps job execution working when its identity extractor fails' do
    job_class.posthog_distinct_id { raise 'identity lookup failed' }
    ActiveJob::Base.execute(snapshot_job)
    expect(observations.first.first(2)).to eq(%w[browser-person browser-session])
  end

  it 'does not let explicit event values change the saved job context' do
    original_observer = job_class.observer
    job_class.observer = lambda do |job|
      original_observer.call(job)
      client.capture(event: 'explicit_job_event', distinct_id: 'explicit-person',
                     properties: { '$session_id' => 'explicit-session' })
    end
    ActiveJob::Base.execute(snapshot_job)
    client.dequeue_last_message
    event = client.dequeue_last_message
    expect(event[:distinct_id]).to eq('explicit-person')
    expect(event[:properties]['$session_id']).to eq('explicit-session')
    expect(observations.first.first(2)).to eq(%w[browser-person browser-session])
  end

  %w[success failure].product(%w[none wrong-id wrong-system]).each do |outcome, marker|
    it "keeps an unrelated caller unchanged across two #{outcome} jobs with #{marker} markers" do
      begin
        require 'opentelemetry-sdk'
      rescue LoadError
        skip 'Install the optional OpenTelemetry bundle'
      end
      require 'posthog/otel/context_span_processor'
      spans = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      provider.add_span_processor(PostHog::ContextSpanProcessor.new)
      provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(spans))
      tracer = provider.tracer('job-caller')
      first = snapshot_job(outcome)
      second = snapshot_job(outcome)
      second['posthog_context'] = { 'distinct_id' => 'second-person', 'session_id' => 'second-session' }
      original_observer = job_class.observer
      job_class.observer = ->(job) { tracer.in_span('child') { original_observer.call(job) } }
      attributes = case marker
                   when 'wrong-id'
                     { 'messaging.system' => 'active_job', 'messaging.message.id' => 'another-job' }
                   when 'wrong-system'
                     { 'messaging.system' => 'other', 'messaging.message.id' => first['job_id'] }
                   else
                     {}
                   end
      tracer.in_span('caller', attributes: attributes) do
        [first, second].each do |payload|
          invoke = -> { ActiveJob::Base.execute(payload) }
          outcome == 'failure' ? expect(&invoke).to(raise_error('job failed')) : invoke.call
        end
      end
      expect(spans.finished_spans.find { |span| span.name == 'caller' }.attributes || {}).to eq(attributes)
      children = spans.finished_spans.select { |span| span.name == 'child' }
      expect(children.map { |span| span.attributes['posthogDistinctId'] }).to eq(%w[browser-person second-person])
      expect(children.map { |span| span.attributes['sessionId'] }).to eq(%w[browser-session second-session])
    ensure
      provider&.shutdown
    end
  end

  it 'adds job IDs to existing and child SDK spans and optional forwarded logs' do
    begin
      require 'opentelemetry-sdk'
      require 'opentelemetry-logs-sdk'
    rescue LoadError
      skip 'Install the gemfiles/otel.gemfile bundle to run span and log integration'
    end
    require 'posthog/otel/context_span_processor'
    require 'posthog/rails/logs/appender'
    spans = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(PostHog::ContextSpanProcessor.new)
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(spans))
    tracer = provider.tracer('active-job-test')
    logs = OpenTelemetry::SDK::Logs::Export::InMemoryLogRecordExporter.new
    logs_provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    logs_provider.add_log_record_processor(OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(logs))
    appender = PostHog::Rails::Logs::Appender.new(logs_provider.logger(name: 'active-job-test'))
    job_class.posthog_distinct_id { 'application-person' }
    job_class.observer = lambda do |_job|
      tracer.in_span('child', attributes: { 'sessionId' => 'explicit-session' }) { appender.info('job ran') }
    end
    payload = snapshot_job
    tracer.in_span('worker', attributes: { 'messaging.system' => 'active_job',
                                           'messaging.message.id' => payload['job_id'] }) do
      ActiveJob::Base.execute(payload)
    end
    by_name = spans.finished_spans.to_h { |span| [span.name, span] }
    expect(by_name['worker'].attributes).to include('posthogDistinctId' => 'application-person',
                                                    'sessionId' => 'browser-session')
    expect(by_name['child'].attributes).to include('posthogDistinctId' => 'application-person',
                                                   'sessionId' => 'explicit-session')
    record = logs.emitted_log_records.first
    expect(record.attributes).to include('posthogDistinctId' => 'application-person', 'sessionId' => 'browser-session')
    expect(record.trace_id).to eq(by_name['child'].trace_id)
    expect(record.span_id).to eq(by_name['child'].span_id)
    expect(context_class.current).to be_nil
  ensure
    provider&.shutdown
    logs_provider&.shutdown
  end

  it 'enriches job spans from the official OpenTelemetry instrumentation' do
    unless Gem.loaded_specs.key?('opentelemetry-instrumentation-active_job')
      skip 'Install the optional OpenTelemetry bundle'
    end

    fixture = File.expand_path('../../fixtures/active_job_span_context.rb', __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib', fixture)
    expect(status.success?).to be(true), output
  end

  it 'leaves serialization and execution unchanged when the integration is disabled' do
    PostHog::Rails.config.auto_instrument_active_job = false
    context_class.with_context(distinct_id: 'application-person', session_id: 'application-session') do
      expect(job_class.new.serialize).not_to have_key('posthog_context')
      job_class.perform_now
    end
    expect(observations.first.first(2)).to eq(%w[application-person application-session])
  end
end
