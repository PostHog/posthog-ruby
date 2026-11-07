# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'active_job'
require 'active_support/parameter_filter'
require 'open3'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'

RSpec.describe 'Active Job retry reporting' do
  let(:context_class) { PostHog.const_get(:Internal).const_get(:Context) }
  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }
  let(:job_class) do
    stub_const('PostHogRetryTestJob', Class.new(ActiveJob::Base) do
      prepend PostHog::Rails::ActiveJobExtensions

      class_attribute :failure
      retry_on StandardError, wait: 0, attempts: 3

      def perform(*)
        raise(self.class.failure || RuntimeError.new('retry failure'))
      end
    end)
    PostHogRetryTestJob.queue_adapter = :test
    PostHogRetryTestJob.logger = Logger.new(File::NULL)
    PostHogRetryTestJob
  end

  around do |example|
    previous_config = PostHog::Rails.config
    previous_client = PostHog.client
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails.config.auto_instrument_active_job = true
    PostHog::Logging.logger = Logger.new(File::NULL)
    PostHog.client = client
    example.run
  ensure
    PostHog::Rails.config = previous_config
    PostHog.client = previous_client
    client.shutdown
  end

  def next_event
    client.dequeue_last_message if client.queued_messages.positive?
  end

  def enable_reporting
    PostHog::Rails.config.report_active_job_retries = true
  end

  def stored_payload
    JSON.parse(JSON.generate(job_class.queue_adapter.enqueued_jobs.last.select { |key, _| key.is_a?(String) }))
  end

  def enqueue_job(*args)
    context_class.with_context(distinct_id: 'saved-person', session_id: 'saved-session',
                               properties: { 'request_only' => 'private' }) do
      job_class.perform_later(*args)
    end
    stored_payload
  end

  it 'defaults to reporting only the terminal unhandled failure' do
    expect(PostHog::Rails.config.report_active_job_retries).to be false
    ActiveJob::Base.execute(enqueue_job)
    expect(next_event).to be_nil
    ActiveJob::Base.execute(stored_payload)
    expect(next_event).to be_nil
    expect { ActiveJob::Base.execute(stored_payload) }.to raise_error('retry failure')
    expect(next_event[:properties]['$job_executions']).to eq(3)
    expect(next_event).to be_nil
  end

  [nil, 'custom-person', 123].each do |identity|
    it "reports actual retries and terminal failure with effective identity #{identity.inspect}" do
      enable_reporting
      job_class.posthog_distinct_id { identity } unless identity.nil?
      payload = enqueue_job('password' => 'secret', 'nested' => { 'token' => 'private', 'safe' => true })
      allow(Rails).to receive(:application).and_return(
        double('app', config: double('config', root: nil, filter_parameters: %i[password token]))
      )
      events = []
      context_class.with_context(distinct_id: 'worker-person', session_id: 'worker-session',
                                 properties: { 'outer_only' => 'private' }) do
        outer = context_class.current
        3.times do |index|
          run = -> { ActiveJob::Base.execute(index.zero? ? payload : stored_payload) }
          index == 2 ? expect(&run).to(raise_error('retry failure')) : run.call
          expect(context_class.current).to equal(outer)
          events << next_event
          expect(next_event).to be_nil
        end
      end
      expect(events.map { |event| event&.dig(:properties, '$job_executions') }).to eq([1, 2, 3])
      events.each do |event|
        expect(event[:event]).to eq('$exception')
        expect(event[:distinct_id]).to eq(identity || 'saved-person')
        expect(event[:properties]).to include(
          '$session_id' => 'saved-session', '$job_class' => 'PostHogRetryTestJob',
          '$job_id' => payload['job_id'], '$queue_name' => 'default',
          '$job_arguments' => [{ 'password' => '[FILTERED]', 'nested' => { 'token' => '[FILTERED]', 'safe' => true } }]
        )
        expect(event[:properties]).not_to include('outer_only', 'request_only')
      end
      events.first(2).each do |event|
        expect(event[:properties]['$exception_source']).to eq('rails.active_job')
        expect(event[:properties]['$exception_level']).to eq('error')
        expect(event[:properties]['$exception_list'].first['mechanism']).to include('type' => 'task',
                                                                                    'handled' => false)
      end
      expect(events.last[:properties]['$exception_source']).to eq('active_job')
      expect(context_class.current).to be_nil
    end
  end

  it 'uses the effective job identity rather than a nested application context' do
    enable_reporting
    job_context = context_class
    job_class.around_perform do |_job, block|
      job_context.with_context(distinct_id: 'nested-person', session_id: 'nested-session') { block.call }
    end
    ActiveJob::Base.execute(enqueue_job)
    event = next_event
    expect(event[:distinct_id]).to eq('saved-person')
    expect(event[:properties]['$session_id']).to eq('saved-session')
    expect(context_class.current).to be_nil
  end

  it 'preserves eventual success and its return value after retries' do
    enable_reporting
    job_class.class_eval do
      def perform(*)
        raise 'retry failure' if executions < 3

        :finished
      end
    end
    ActiveJob::Base.execute(enqueue_job)
    expect(next_event[:properties]['$job_executions']).to eq(1)
    ActiveJob::Base.execute(stored_payload)
    expect(next_event[:properties]['$job_executions']).to eq(2)
    expect(ActiveJob::Base.execute(stored_payload)).to eq(:finished)
    expect(next_event).to be_nil
  end

  it 'does not let reporting failures interrupt retry scheduling or replace the terminal error' do
    enable_reporting
    allow(PostHog).to receive(:capture_exception).and_raise('reporting failed')
    ActiveJob::Base.execute(enqueue_job)
    ActiveJob::Base.execute(stored_payload)
    expect { ActiveJob::Base.execute(stored_payload) }.to raise_error('retry failure')
    expect(job_class.queue_adapter.enqueued_jobs.size).to eq(3)
    expect(context_class.current).to be_nil
  end

  it 'does not install duplicate handlers when multiple job classes are instrumented' do
    enable_reporting
    stub_const('PostHogOtherRetryJob', Class.new(ActiveJob::Base) do
      prepend PostHog::Rails::ActiveJobExtensions
    end)
    allow(PostHog).to receive(:capture_exception).and_call_original
    ActiveJob::Base.execute(enqueue_job)
    expect(PostHog).to have_received(:capture_exception).once
  end

  it 'retains core deduplication for a shared exception across retries and terminal failure' do
    enable_reporting
    job_class.failure = RuntimeError.new('shared failure')
    ActiveJob::Base.execute(enqueue_job)
    expect(next_event[:event]).to eq('$exception')
    ActiveJob::Base.execute(stored_payload)
    expect { ActiveJob::Base.execute(stored_payload) }.to raise_error(job_class.failure)
    expect(next_event).to be_nil
  end

  it 'does not report retries when Active Job instrumentation is disabled' do
    enable_reporting
    PostHog::Rails.config.auto_instrument_active_job = false
    ActiveJob::Base.execute(enqueue_job)
    expect(next_event).to be_nil
  end

  [false, true].each do |nested|
    %i[configured default].each do |exclusion|
      it "schedules retries without reporting #{exclusion} exclusions with nested=#{nested}" do
        enable_reporting
        excluded_class = if exclusion == :configured
                           PostHog::Rails.config.excluded_exceptions = ['ArgumentError']
                           ArgumentError
                         else
                           stub_const('ActiveRecord::RecordNotFound', Class.new(StandardError))
                         end
        excluded = excluded_class.new('excluded failure')
        job_class.failure = if nested
                              begin
                                raise RuntimeError.new('wrapper'), cause: excluded
                              rescue RuntimeError => e
                                e
                              end
                            else
                              excluded
                            end
        ActiveJob::Base.execute(enqueue_job)
        expect(job_class.queue_adapter.enqueued_jobs.size).to eq(2)
        expect(next_event).to be_nil
      end
    end
  end

  [50, 51].each do |position|
    it "checks exclusions only within the serialized chain at position #{position}" do
      enable_reporting
      PostHog::Rails.config.excluded_exceptions = ['ArgumentError']
      failure = ArgumentError.new('excluded cause')
      (position - 1).times do
        cause = failure
        failure = RuntimeError.new('wrapper')
        failure.define_singleton_method(:cause) { cause }
      end
      job_class.failure = failure
      ActiveJob::Base.execute(enqueue_job)
      expect(job_class.queue_adapter.enqueued_jobs.size).to eq(2)
      event = next_event
      if position == 50
        expect(event).to be_nil
      else
        expect(event[:properties]['$exception_list'].size).to eq(50)
      end
    end
  end

  it 'reports an unexcluded cycle once without traversing it again' do
    enable_reporting
    failure = RuntimeError.new('cyclic failure')
    failure.define_singleton_method(:cause) { failure }
    job_class.failure = failure
    ActiveJob::Base.execute(enqueue_job)
    expect(job_class.queue_adapter.enqueued_jobs.size).to eq(2)
    expect(next_event[:properties]['$exception_list'].size).to eq(1)
    expect(next_event).to be_nil
  end

  it 'uses the existing argument identity fallback' do
    enable_reporting
    ActiveJob::Base.execute(enqueue_job('user_id' => 'argument-person'))
    expect(next_event[:distinct_id]).to eq('argument-person')
  end

  it 'clears unrelated worker context for older jobs without saved identity' do
    enable_reporting
    payload = enqueue_job
    payload.delete('posthog_context')
    context_class.with_context(distinct_id: 'worker-person', session_id: 'worker-session') do
      outer = context_class.current
      ActiveJob::Base.execute(payload)
      expect(context_class.current).to equal(outer)
    end
    event = next_event
    expect(event[:distinct_id]).not_to eq('worker-person')
    expect(event[:properties]).not_to have_key('$session_id')
  end

  it 'keeps retries working when an identity extractor raises' do
    enable_reporting
    job_class.posthog_distinct_id { raise 'lookup failed' }
    ActiveJob::Base.execute(enqueue_job)
    expect(next_event[:distinct_id]).to eq('saved-person')
  end

  context 'with a failing before_send privacy hook' do
    let(:client) do
      PostHog::Client.new(api_key: API_KEY, test_mode: true, before_send: ->(_event) { raise 'scrubber failed' })
    end

    it 'drops the event and preserves retries' do
      enable_reporting
      expect { ActiveJob::Base.execute(enqueue_job) }.not_to raise_error
      expect(job_class.queue_adapter.enqueued_jobs.size).to eq(2)
      expect(next_event).to be_nil
    end
  end

  %i[discard rescue terminal_retry].each do |handler|
    it "does not broaden reporting to #{handler} handlers" do
      enable_reporting
      case handler
      when :discard then job_class.discard_on RuntimeError
      when :rescue then job_class.rescue_from(RuntimeError) { nil }
      when :terminal_retry then job_class.retry_on(RuntimeError, attempts: 1) { nil }
      end
      ActiveJob::Base.execute(enqueue_job)
      expect(next_event).to be_nil
    end
  end

  [nil, ''].each do |api_key|
    it "no-ops safely with #{api_key.inspect} client availability" do
      enable_reporting
      if api_key
        disabled_client = PostHog::Client.new(api_key: api_key, test_mode: true,
                                              silence_disabled_client_error: true)
      end
      PostHog.client = disabled_client
      ActiveJob::Base.execute(enqueue_job)
      expect(next_event).to be_nil
      expect(disabled_client&.queued_messages.to_i).to eq(0)
      expect(PostHog.client).to equal(disabled_client)
    ensure
      disabled_client&.shutdown
    end
  end

  it 'preserves the standalone retry lifecycle with matched framework packages' do
    output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib',
                                     'spec/fixtures/active_job_retry_lifecycle.rb')
    expect(status.success?).to be(true), output
  end

  %w[before after].each do |load_order|
    it "registers through Rails initialization with Active Job loaded #{load_order} the hook" do
      script = <<~RUBY
        require 'rails'
        require 'active_job' if #{load_order == 'before'}
        require 'posthog'
        require 'posthog/rails'
        PostHog::Rails.configure do |config|
          config.auto_instrument_active_job = true
          config.report_active_job_retries = true
        end
        Rails.logger = Logger.new(File::NULL)
        PostHog.init(api_key: 'phc_fixture', test_mode: true)
        require 'tmpdir'
        root = Dir.mktmpdir('posthog-retry-app')
        at_exit { FileUtils.remove_entry(root) }
        class RetryHookApp < Rails::Application
          config.eager_load = false
          config.secret_key_base = 'retry-hook-test-secret'
          config.logger = Logger.new(File::NULL)
        end
        RetryHookApp.config.root = root
        RetryHookApp.initialize!
        require 'active_job'
        class RetryHookJob < ActiveJob::Base
          self.queue_adapter = :test
          self.logger = Logger.new(File::NULL)
          retry_on RuntimeError, wait: 0, attempts: 2
          def perform
            raise 'hook retry'
          end
        end
        RetryHookJob.perform_now
        event = PostHog.client.dequeue_last_message if PostHog.client.queued_messages.positive?
        abort 'retry missing' unless event && event[:event] == '$exception'
        abort 'duplicate retry' unless PostHog.client.queued_messages.zero?
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib', '-e', script)
      expect(status.success?).to be(true), output
    end
  end
end
