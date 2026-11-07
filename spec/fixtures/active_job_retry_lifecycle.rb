# frozen_string_literal: true

require 'logger'
require 'json'
require 'active_job'
require 'posthog'

# Standalone Active Job harness, not a booted Rails application. These accessors
# supply only the Rails integration's version and absent application/config host.
module Rails
  def self.version
    ActiveJob::VERSION::STRING
  end

  def self.application
    nil
  end
end

require 'posthog/rails/configuration'
require 'posthog/rails/active_job'
require 'posthog/rails/facade'

module PostHog
  module Rails
    class << self
      attr_accessor :config
    end
  end
end
PostHog::Rails.install_posthog_facade!
PostHog::Rails.config = PostHog::Rails::Configuration.new
PostHog::Rails.config.auto_instrument_active_job = true
PostHog::Logging.logger = Logger.new(File::NULL)
PostHog.init(api_key: 'phc_fixture', test_mode: true)

# Active Job 5.2's test adapter retains arguments, not the full serialized job.
class RetryLifecycleAdapter < ActiveJob::QueueAdapters::TestAdapter
  attr_reader :payload

  def enqueue(job)
    @payload = JSON.parse(JSON.generate(job.serialize))
    super
  end

  def enqueue_at(job, timestamp)
    @payload = JSON.parse(JSON.generate(job.serialize))
    super
  end
end

class RetryLifecycleJob < ActiveJob::Base
  prepend PostHog::Rails::ActiveJobExtensions

  self.queue_adapter = RetryLifecycleAdapter.new
  self.logger = Logger.new(File::NULL)
  class_attribute :handler_calls, default: 0
  class_attribute :last_failure
  posthog_distinct_id { 'job-person' }
  retry_on RuntimeError, wait: 0, attempts: 2

  def perform
    self.class.last_failure = RuntimeError.new('lifecycle failure')
    raise self.class.last_failure
  end
end

context = PostHog.const_get(:Internal).const_get(:Context)
client = PostHog.client
config = PostHog::Rails.config

def assert_lifecycle(condition, message)
  raise message unless condition
end

def lifecycle_event
  PostHog.client.dequeue_last_message if PostHog.client.queued_messages.positive?
end

def lifecycle_payload
  RetryLifecycleJob.queue_adapter.payload
end

[false, true].each do |enabled|
  config.report_active_job_retries = enabled
  context.with_context(distinct_id: 'saved-person', session_id: 'saved-session',
                       properties: { 'request' => 'secret' }) do
    RetryLifecycleJob.perform_later
  end
  before_retry = RetryLifecycleJob.queue_adapter.enqueued_jobs.size
  context.with_context(distinct_id: 'worker-person', session_id: 'worker-session') do
    outer = context.current
    result = ActiveJob::Base.execute(lifecycle_payload)
    assert_lifecycle(result.equal?(RetryLifecycleJob.last_failure), 'handler return changed')
    assert_lifecycle(context.current.equal?(outer), 'worker context changed')
  end
  assert_lifecycle(RetryLifecycleJob.queue_adapter.enqueued_jobs.size == before_retry + 1, 'retry not scheduled once')
  event = lifecycle_event
  assert_lifecycle(!event.nil? == enabled, "expected #{enabled ? 1 : 0} retry events, got #{event ? 1 : 0}")
  if event
    assert_lifecycle(event[:distinct_id] == 'job-person', 'extractor identity lost')
    assert_lifecycle(event[:properties]['$session_id'] == 'saved-session', 'saved session lost')
    assert_lifecycle(event[:properties]['$exception_source'] == 'rails.active_job', 'retry source lost')
    assert_lifecycle(!event[:properties].key?('request'), 'request properties leaked')
  end
  begin
    ActiveJob::Base.execute(lifecycle_payload)
    raise 'terminal error swallowed'
  rescue RuntimeError => e
    assert_lifecycle(e.equal?(RetryLifecycleJob.last_failure), 'terminal error replaced')
  end
  assert_lifecycle(lifecycle_event&.dig(:properties, '$exception_source') == 'active_job', 'terminal event missing')
  assert_lifecycle(lifecycle_event.nil?, 'duplicate event')
  assert_lifecycle(context.current.nil?, 'context leaked')
end

config.report_active_job_retries = true
%i[discard rescue terminal_retry].each do |handler|
  klass = Class.new(RetryLifecycleJob)
  Object.const_set("RetryLifecycle#{handler.to_s.camelize}Job", klass)
  case handler
  when :discard then klass.discard_on(RuntimeError) { klass.handler_calls += 1 }
  when :rescue then klass.rescue_from(RuntimeError) { klass.handler_calls += 1 }
  when :terminal_retry then klass.retry_on(RuntimeError, attempts: 1) { klass.handler_calls += 1 }
  end
  klass.perform_now
  assert_lifecycle(klass.handler_calls == 1, "#{handler} handler called more than once")
  assert_lifecycle(lifecycle_event.nil?, "#{handler} gained a report")
end

config.excluded_exceptions = ['ArgumentError']
class ExcludedRetryLifecycleJob < RetryLifecycleJob
  def perform
    raise ArgumentError, 'excluded'
  rescue ArgumentError
    raise 'wrapper'
  end
end
before_retry = RetryLifecycleJob.queue_adapter.enqueued_jobs.size
ExcludedRetryLifecycleJob.perform_now
assert_lifecycle(RetryLifecycleJob.queue_adapter.enqueued_jobs.size == before_retry + 1, 'excluded retry not scheduled')
assert_lifecycle(lifecycle_event.nil?, 'excluded retry reported')

job = RetryLifecycleJob.new
job.perform_now
lifecycle_event
result = job.retry_job(wait: 0)
assert_lifecycle(result.is_a?(RetryLifecycleJob) && result.job_id == job.job_id, 'retry_job return changed')
assert_lifecycle(result.equal?(job), 'legacy retry_job no longer returns self') if ActiveJob::VERSION::MAJOR < 6
assert_lifecycle(lifecycle_event.nil?, 'stale handler error reported')

config.auto_instrument_active_job = false
RetryLifecycleJob.perform_now
assert_lifecycle(lifecycle_event.nil?, 'disabled instrumentation reported')
config.auto_instrument_active_job = true
PostHog.client = nil
RetryLifecycleJob.perform_now
assert_lifecycle(PostHog.client.nil?, 'uninitialized client replaced')
PostHog.init(api_key: '', test_mode: true, silence_disabled_client_error: true)
RetryLifecycleJob.perform_now
assert_lifecycle(lifecycle_event.nil?, 'disabled client reported')
PostHog.client.shutdown
client.shutdown
puts "Active Job #{ActiveJob::VERSION::STRING}: retry lifecycle controls passed"
