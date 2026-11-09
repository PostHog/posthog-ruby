# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rails'
require 'rails/railtie'
require 'action_dispatch'
require 'active_job'
require 'sidekiq'
require 'sidekiq/processor'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'
require 'posthog/rails/sidekiq'

RSpec.describe 'Sidekiq retry reporting' do
  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }
  let(:config) { Sidekiq::Config.new(error_handlers: [], death_handlers: []) }
  let(:reporter) { ActiveSupport::ErrorReporter.new }
  let(:stored_jobs) { Hash.new { |hash, key| hash[key] = [] } }
  let(:job) do
    { 'class' => 'RetryPolicyJob', 'args' => [], 'queue' => 'default', 'jid' => 'job-123', 'retry' => 2 }
  end

  around do |example|
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails.config.auto_capture_exceptions = true
    example.run
  ensure
    PostHog::Rails.config = previous_config
  end

  before do
    allow(PostHog).to receive(:client).and_return(client)
    allow(PostHog).to receive(:initialized?).and_return(true)
    allow(Sidekiq).to receive(:default_configuration).and_return(config)
    config.logger = Logger.new(File::NULL)
    config.error_handlers.clear
    reporter.subscribe(PostHog::Rails::ErrorSubscriber.new)
    config[:reloader] = ->(&block) { reporter.record(source: 'job.sidekiq', &block) }

    redis = double('Redis')
    allow(redis).to receive(:zadd) { |key, _score, payload| stored_jobs[key] << Sidekiq.load_json(payload) }
    allow(redis).to receive(:multi).and_yield(redis)
    allow(redis).to receive(:zremrangebyscore)
    allow(redis).to receive(:zremrangebyrank)
    allow(config).to receive(:redis).and_yield(redis)
    allow(config.default_capsule).to receive(:redis).and_yield(redis)

    stub_const('RetryPolicyJob', Class.new do
      include Sidekiq::Job

      def perform
        raise 'job failed'
      end
    end)
  end

  def enable_policy(policy)
    PostHog::Rails::Sidekiq.install(config, error_reporting: policy)
  end

  def run_work(work, server_config = config)
    capsule = server_config.default_capsule
    result = Queue.new
    processor = Sidekiq::Processor.new(capsule) do |_worker, error|
      result << [error, PostHog::Rails::Sidekiq.in_job?]
    end
    retrieved = false
    fetcher = double('fetcher')
    allow(fetcher).to receive(:retrieve_work) do
      if retrieved
        processor.terminate
        nil
      else
        retrieved = true
        work
      end
    end
    allow(capsule).to receive(:fetcher).and_return(fetcher)

    processor.start
    expect(processor.thread.join(5)).not_to be_nil
    error, in_job = result.pop
    expect(in_job).to be_falsey
    error
  ensure
    processor&.kill(true) if processor&.thread&.alive?
  end

  def process_failure(payload = job)
    work = Sidekiq::BasicFetch::UnitOfWork.new('queue:default', Sidekiq.dump_json(payload), config)
    allow(work).to receive(:acknowledge)
    error = run_work(work)
    expect(error).to be_a(RuntimeError)
    expect(error.message).to eq('job failed')
    expect(work).to have_received(:acknowledge).once
  end

  def process_retries
    process_failure
    expect(stored_jobs['retry'].size).to eq(1)
    process_failure(stored_jobs['retry'].shift)
    expect(stored_jobs['retry'].size).to eq(1)
    process_failure(stored_jobs['retry'].shift)
    expect(stored_jobs['retry']).to be_empty
    expect(stored_jobs['dead'].size).to eq(1)
  end

  it 'keeps the policy disabled by default' do
    expect(PostHog::Rails.config).not_to respond_to(:sidekiq_error_reporting)
    expect(config.error_handlers).to be_empty
    expect(config.death_handlers).to be_empty
    config.error_handlers << ->(_error, _context, _config) {}

    process_retries

    expect(client.queued_messages).to eq(3)
  end

  it 'reports Sidekiq failures without enabling Rails automatic exception capture' do
    PostHog::Rails.config.auto_capture_exceptions = false
    enable_policy(:exhausted)

    process_retries

    expect(client.queued_messages).to eq(1)
  end

  %i[all exhausted].each do |policy|
    it "owns failures before middleware runs in #{policy} mode" do
      enable_policy(policy)
      job['class'] = 'MissingRetryPolicyJob'
      work = Sidekiq::BasicFetch::UnitOfWork.new('queue:default', Sidekiq.dump_json(job), config)
      allow(work).to receive(:acknowledge)

      expect(run_work(work)).to be_a(NameError)

      expect(work).to have_received(:acknowledge).once
      expect(stored_jobs['retry'].size).to eq(1)
      expect(client.queued_messages).to eq(policy == :all ? 1 : 0)
      if policy == :all
        expect(client.dequeue_last_message[:properties]['$exception_list'].first['type']).to eq('NameError')
      end
    end
  end

  it 'keeps later global middleware visible to an existing uncached capsule' do
    capsule = config.default_capsule
    calls = []
    middleware = Class.new do
      define_method(:call) do |_worker, _job, _queue, &block|
        calls << :called
        block.call
      end
    end
    enable_policy(:exhausted)
    config.server_middleware { |chain| chain.add(middleware) }

    owned = capsule.server_middleware.invoke(nil, job, 'default') do
      PostHog::Rails::Sidekiq.in_job?
    end

    expect(calls).to eq([:called])
    expect(owned).to be(true)
    expect(PostHog::Rails::Sidekiq.in_job?).to be_falsey
  end

  it 'installs reporting ownership into an already-cached capsule chain' do
    chain = config.default_capsule.server_middleware
    enable_policy(:exhausted)

    owned = chain.invoke(nil, job, 'default') { PostHog::Rails::Sidekiq.in_job? }

    expect(owned).to be(true)
    expect(PostHog::Rails::Sidekiq.in_job?).to be_falsey
  end

  it 'does not change another server configuration that shares the original handler arrays' do
    other_config = Sidekiq::Config.new(error_handlers: config.error_handlers, death_handlers: config.death_handlers)
    other_config.error_handlers.clear
    other_config.logger = Logger.new(File::NULL)
    allow(other_config).to receive(:redis) { |&block| config.redis(&block) }
    allow(other_config.default_capsule).to receive(:redis) { |&block| config.redis(&block) }
    enable_policy(:exhausted)

    expect(other_config.error_handlers).to be_empty
    expect(other_config.death_handlers).to be_empty
    other_config.error_handlers << ->(_error, _context, _config) {}
    work = Sidekiq::BasicFetch::UnitOfWork.new(
      'queue:default', Sidekiq.dump_json(job.merge('retry' => 0)), other_config
    )
    allow(work).to receive(:acknowledge)

    expect(run_work(work, other_config)).to be_a(RuntimeError)

    expect(client.queued_messages).to eq(1)
    expect(client.dequeue_last_message[:properties]['$exception_list'].first['type']).to eq('RuntimeError')
  end

  it 'releases reporting ownership for Sidekiq skip exceptions without capturing them' do
    enable_policy(:all)
    allow_any_instance_of(RetryPolicyJob).to receive(:perform).and_raise(Sidekiq::JobRetry::Skip)
    work = Sidekiq::BasicFetch::UnitOfWork.new('queue:default', Sidekiq.dump_json(job), config)
    allow(work).to receive(:acknowledge)

    expect(run_work(work)).to be_a(Sidekiq::JobRetry::Skip)

    expect(work).to have_received(:acknowledge).once
    expect(client.queued_messages).to eq(0)
    expect(stored_jobs['retry']).to be_empty
    expect(stored_jobs['dead']).to be_empty
  end

  it 'reports every failed attempt once in all mode' do
    enable_policy(:all)

    process_retries

    expect(client.queued_messages).to eq(3)
    3.times do
      properties = client.dequeue_last_message[:properties]
      expect(properties['$exception_list'].map { |entry| entry['type'] }).to eq(['RuntimeError'])
      expect(properties).to include('$exception_source' => 'sidekiq.error_handler', '$exception_level' => 'error')
      expect(properties['$exception_list'].first['mechanism']).to include('type' => 'task', 'handled' => false)
    end
  end

  %i[exhausted dead].each do |policy|
    it "reports only the final attempt in #{policy} mode" do
      enable_policy(policy)

      process_failure
      expect(client.queued_messages).to eq(0)
      process_failure(stored_jobs['retry'].shift)
      expect(client.queued_messages).to eq(0)
      process_failure(stored_jobs['retry'].shift)

      expect(client.queued_messages).to eq(1)
      expect(stored_jobs['dead'].size).to eq(1)
      expect(client.dequeue_last_message[:properties]['$exception_source']).to eq('sidekiq.death_handler')
    end
  end

  { exhausted: 1, dead: 0 }.each do |policy, events|
    [false, 0].each do |retry_option|
      it "honors retry=#{retry_option} in #{policy} mode" do
        enable_policy(policy)
        job['retry'] = retry_option

        process_failure

        expect(stored_jobs['retry']).to be_empty
        expect(stored_jobs['dead'].size).to eq(retry_option == false ? 0 : 1)
        expect(client.queued_messages).to eq(retry_option == false ? events : 1)
      end
    end

    it "reports #{events} terminal events with dead=false in #{policy} mode" do
      enable_policy(policy)
      job.merge!('retry' => 0, 'dead' => false)

      process_failure

      expect(stored_jobs['retry']).to be_empty
      expect(stored_jobs['dead']).to be_empty
      expect(client.queued_messages).to eq(events)
    end
  end

  it 'uses the terminal callback for an early kill instead of comparing retry counts' do
    enable_policy(:exhausted)
    RetryPolicyJob.sidekiq_retry_in { :kill }

    process_failure

    expect(stored_jobs['retry']).to be_empty
    expect(stored_jobs['dead'].size).to eq(1)
    expect(client.queued_messages).to eq(1)
  end

  it 'uses the terminal callback when the retry duration expires before the retry limit' do
    enable_policy(:exhausted)
    job.merge!('retry' => 1000, 'retry_for' => 10, 'failed_at' => 1.0, 'retry_count' => 0)

    process_failure

    expect(stored_jobs['retry']).to be_empty
    expect(stored_jobs['dead'].size).to eq(1)
    expect(client.queued_messages).to eq(1)
  end

  %i[all exhausted dead].each do |policy|
    it "honors Sidekiq's discard notification in #{policy} mode" do
      enable_policy(policy)
      RetryPolicyJob.sidekiq_retry_in { :discard }

      process_failure

      expect(stored_jobs['retry']).to be_empty
      expect(stored_jobs['dead']).to be_empty
      expected = policy == :all || (policy == :exhausted && Gem::Version.new(Sidekiq::VERSION) >= Gem::Version.new('8.1'))
      expect(client.queued_messages).to eq(expected ? 1 : 0)
    end
  end

  it 'does not report a job that succeeds on its next attempt in exhausted mode' do
    enable_policy(:exhausted)
    process_failure
    allow_any_instance_of(RetryPolicyJob).to receive(:perform).and_return(:success)
    work = Sidekiq::BasicFetch::UnitOfWork.new(
      'queue:default', Sidekiq.dump_json(stored_jobs['retry'].shift), config
    )
    allow(work).to receive(:acknowledge)

    expect(run_work(work)).to be_nil

    expect(work).to have_received(:acknowledge).once
    expect(client.queued_messages).to eq(0)
    expect(stored_jobs['dead']).to be_empty
  end

  %i[all exhausted dead].each do |policy|
    it "does not let Active Job bypass the #{policy} policy" do
      config.default_capsule.server_middleware
      enable_policy(policy)
      PostHog::Rails.config.auto_instrument_active_job = true
      stub_const('InnerPolicyJob', Class.new(ActiveJob::Base) do
        prepend PostHog::Rails::ActiveJobExtensions

        self.logger = Logger.new(File::NULL)

        def perform
          raise 'job failed'
        end
      end)
      InnerPolicyJob.posthog_distinct_id -> { 'job-user' }
      allow_any_instance_of(RetryPolicyJob).to receive(:perform) do
        PostHog.const_get(:Internal)::Context.with_context(session_id: 'job-session') { InnerPolicyJob.perform_now }
      end

      process_retries

      expect(client.queued_messages).to eq(policy == :all ? 3 : 1)
      event = client.dequeue_last_message
      expect(event[:distinct_id]).to eq('job-user')
      expect(event[:properties]).to include('$job_class' => 'InnerPolicyJob', '$session_id' => 'job-session')
    end
  end

  it 'keeps reporting ownership when Sidekiq handles another error while the job is running' do
    enable_policy(:exhausted)
    PostHog::Rails.config.auto_instrument_active_job = true
    stub_const('FailureAfterInternalReport', Class.new(ActiveJob::Base) do
      prepend PostHog::Rails::ActiveJobExtensions

      self.logger = Logger.new(File::NULL)

      def perform
        raise 'job failed'
      end
    end)
    allow_any_instance_of(RetryPolicyJob).to receive(:perform) do
      config.handle_exception(ArgumentError.new('internal error'), {})
      FailureAfterInternalReport.perform_now
    end

    process_retries

    expect(client.queued_messages).to eq(1)
  end

  it 'honors exclusions on the original job error' do
    enable_policy(:exhausted)
    PostHog::Rails.config.excluded_exceptions = ['RuntimeError']

    process_retries

    expect(client.queued_messages).to eq(0)
  end

  it 'honors exclusions in the original error cause chain' do
    enable_policy(:exhausted)
    PostHog::Rails.config.excluded_exceptions = ['ArgumentError']
    allow_any_instance_of(RetryPolicyJob).to receive(:perform) do
      raise 'job failed', cause: ArgumentError.new('ignored cause')
    end

    process_retries

    expect(client.queued_messages).to eq(0)
  end

  it 'leaves deliberate Rails reports and manual captures outside the retry policy' do
    enable_policy(:exhausted)
    allow_any_instance_of(RetryPolicyJob).to receive(:perform) do
      reporter.report(ArgumentError.new('handled'), handled: true, source: 'application.custom')
      client.capture_exception(ArgumentError.new('manual'))
      raise 'job failed'
    end

    process_failure

    expect(client.queued_messages).to eq(2)
    expect(stored_jobs['retry'].size).to eq(1)
  end

  it 'does not acknowledge or report an interrupted job during shutdown' do
    enable_policy(:all)
    allow_any_instance_of(RetryPolicyJob).to receive(:perform).and_raise(Sidekiq::Shutdown)
    work = Sidekiq::BasicFetch::UnitOfWork.new('queue:default', Sidekiq.dump_json(job), config)
    allow(work).to receive(:acknowledge)

    expect(run_work(work)).to be_nil

    expect(work).not_to have_received(:acknowledge)
    expect(stored_jobs['retry']).to be_empty
    expect(stored_jobs['dead']).to be_empty
    expect(client.queued_messages).to eq(0)
    expect(PostHog::Rails::Sidekiq.in_job?).to be_falsey
  end

  it 'does not register duplicate middleware or handlers' do
    enable_policy(:exhausted)
    PostHog::Rails::Sidekiq.install(config, error_reporting: :exhausted)
    expect(config.error_handlers.size).to eq(1)
    expect(config.death_handlers.size).to eq(1)

    process_retries

    expect(client.queued_messages).to eq(1)
  end

  it 'updates the installed policy without adding duplicate handlers' do
    enable_policy(:all)
    enable_policy(:exhausted)

    process_retries

    expect(client.queued_messages).to eq(1)
    expect(config.error_handlers.size).to eq(1)
    expect(config.death_handlers.size).to eq(1)
  end

  it 'leaves other Sidekiq handlers and Rails subscribers active' do
    enable_policy(:exhausted)
    other_errors = []
    config.error_handlers << ->(error, _context, _config) { other_errors << error }
    other_subscriber = spy('other Rails subscriber')
    reporter.subscribe(other_subscriber)

    process_retries

    expect(other_errors.map(&:message)).to eq(['job failed'] * 3)
    expect(other_subscriber).to have_received(:report).exactly(3).times
    expect(client.queued_messages).to eq(1)
  end

  it 'does not change retry scheduling when PostHog capture raises' do
    enable_policy(:exhausted)
    allow(PostHog).to receive(:capture_exception).and_raise('capture failed')

    process_retries

    expect(client.queued_messages).to eq(0)
  end

  it 'does not capture infrastructure errors without a job' do
    enable_policy(:all)

    config.handle_exception(RuntimeError.new('Redis failed'), {})

    expect(client.queued_messages).to eq(0)
  end

  [%w[sidekiq/cli posthog/rails/sidekiq], %w[posthog/rails/sidekiq sidekiq/cli]].each do |load_order|
    it "installs the policy during Rails boot with #{load_order.join(' loaded before ')}" do
      script = <<~RUBY
        require 'tmpdir'
        require 'posthog'
        require 'rails'
        require 'action_dispatch'
        #{load_order.map { |library| "require '#{library}'" }.join("\n")}
        Sidekiq.default_configuration.logger = Logger.new(File::NULL)
        PostHog::Logging.logger = Logger.new(File::NULL)
        PostHog.init(api_key: 'test', test_mode: true)
        config = Sidekiq.default_configuration
        previous_error_handlers = config.error_handlers.size
        previous_death_handlers = config.death_handlers.size
        Sidekiq.configure_server do |server_config|
          PostHog::Rails::Sidekiq.install(server_config, error_reporting: :exhausted)
        end
        Dir.mktmpdir do |root|
          app = Class.new(Rails::Application)
          app.config.root = root
          app.config.eager_load = false
          app.config.secret_key_base = 'test' * 32
          app.config.logger = Logger.new(File::NULL)
          app.initialize!
          abort 'missing error handler' unless config.error_handlers.size == previous_error_handlers + 1
          abort 'missing death handler' unless config.death_handlers.size == previous_death_handlers + 1
          middleware = PostHog::Rails::Sidekiq.const_get(:ServerMiddleware)
          abort 'missing middleware' unless config.server_middleware.exists?(middleware)
          abort 'unexpected Rails option' if PostHog::Rails.config.respond_to?(:sidekiq_error_reporting)
          puts 'sidekiq-policy-installed'
        end
      RUBY

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib', '-e', script)

      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include('sidekiq-policy-installed')
    end
  end

  it 'installs the policy at the Sidekiq 7.0.3 minimum' do
    stub_const('Sidekiq::VERSION', '7.0.3')
    enable_policy(:dead)
    job['retry'] = false

    process_failure

    expect(client.queued_messages).to eq(0)
  end

  [
    ['7.0.8', '7.3.9'], ['7.2.3.1', '6.5.0'],
    ['7.2.3.1', '7.0.0'], ['7.2.3.1', '7.0.1'], ['7.2.3.1', '7.0.2']
  ].each do |rails_version, sidekiq_version|
    it "keeps existing reporting on unsupported Rails #{rails_version} / Sidekiq #{sidekiq_version}" do
      allow(Rails).to receive(:version).and_return(rails_version)
      stub_const('Sidekiq::VERSION', sidekiq_version)
      expect(PostHog::Logging.logger).to receive(:warn).with(include('requires Rails 7.1+ and Sidekiq 7.0.3+'))
      config[:reloader] = ->(&block) { reporter.record(source: 'application.active_support', &block) }

      enable_policy(:dead)

      expect(config.error_handlers).to be_empty
      expect(config.death_handlers).to be_empty
      job['retry'] = false

      process_failure

      expect(client.queued_messages).to eq(1)
      expect(client.dequeue_last_message[:properties]['$exception_source']).to eq('application.active_support')
    end
  end

  it 'does not load the optional integration or Sidekiq through the Rails integration' do
    script = <<~RUBY
      require 'rails'
      require 'posthog-rails'
      abort 'Sidekiq was loaded' if defined?(::Sidekiq)
      abort 'integration was loaded' if PostHog::Rails.const_defined?(:Sidekiq, false)
      abort 'unexpected Rails option' if PostHog::Rails.config.respond_to?(:sidekiq_error_reporting)
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib', '-e', script)

    expect(status).to be_success, "#{stdout}\n#{stderr}"
  end

  it 'rejects invalid reporting policies without changing the installed policy' do
    enable_policy(:exhausted)

    expect { enable_policy(:sometimes) }.to raise_error(ArgumentError)

    process_retries

    expect(client.queued_messages).to eq(1)
    expect(config.error_handlers.size).to eq(1)
  end
end
