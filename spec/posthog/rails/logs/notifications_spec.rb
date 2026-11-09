# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'action_controller/railtie'
require 'action_controller/base'
require 'active_job'
require 'open3'

$LOAD_PATH.unshift File.expand_path('../../../../posthog-rails/lib', __dir__)
require 'posthog/rails'

RSpec.describe 'Rails structured notification logs' do
  let(:records) { [] }
  let(:otel_logger) do
    sink = double('otel_logger')
    allow(sink).to receive(:on_emit) { |**record| records << record }
    sink
  end
  let(:provider) { double('provider', logger: otel_logger, shutdown: nil) }
  let(:config) { PostHog::Rails.config }

  around do |example|
    previous_config = PostHog::Rails.config
    previous_client = PostHog.client
    previous_job_logger = ActiveJob::Base.logger
    ActiveJob::Base.logger = Logger.new(File::NULL)
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails::Logs::Setup.reset
    PostHog::Logging.logger = Logger.new(File::NULL)
    PostHog.init(api_key: 'phc_test', test_mode: true)
    example.run
  ensure
    PostHog::Rails::Logs::Setup.reset
    PostHog.client&.shutdown
    PostHog.client = previous_client
    ActiveJob::Base.logger = previous_job_logger
    PostHog::Rails.config = previous_config
  end

  def install(components = %i[action_controller active_record active_job action_mailer], level: :debug)
    config.logs_enabled = true
    config.logs_notifications = components
    config.logs_level = level
    PostHog::Rails::Logs::Setup.remember_client_options(api_key: 'phc_test')
    allow(PostHog::Rails::Logs::Setup).to receive_messages(require_otel_gems: true, build_provider: provider)
    PostHog::Rails::Logs::Setup.install
  end

  def load_optional_components
    # These components are not required by the gem or the base development bundle.
    ActiveSupport.run_load_hooks(:active_record, Class.new)
    ActiveSupport.run_load_hooks(:action_mailer, Class.new)
  end

  def notify(name = 'process_action.action_controller', **payload)
    ActiveSupport::Notifications.instrument(name, payload) { :original_result }
  end

  def emit_job_parameters(params)
    install([:active_job])
    job_class = Class.new(ActiveJob::Base) do
      def perform(*)
        :original_result
      end
    end
    stub_const('CustomFilterLogsJob', job_class)
    expect(job_class.new(params).perform_now).to eq(:original_result)
    JSON.parse(records.fetch(0)[:attributes].fetch('rails.job.arguments')).first
  end

  context 'with Active Job custom parameter filters' do
    def configure_parameter_filter(filter)
      app = double('application', config: double('config', root: nil, filter_parameters: Array(filter)))
      allow(Rails).to receive(:application).and_return(app)
    end

    it 'preserves symbol/string keys, symbol values and original-root semantics without mutating app data' do
      filter = proc do |key, value, original|
        mask = key == :secret || key == 'string_secret' ||
               (key == :dependent && original[:mode] == :private)
        value.replace('[FILTERED]') if mask && value.is_a?(String)
      end
      configure_parameter_filter(filter)
      params = { mode: :private, secret: 'PRIVATE_SYMBOL'.dup, 'string_secret' => 'PRIVATE_STRING'.dup,
                 dependent: 'PRIVATE_ROOT'.dup, nested: [{ secret: 'PRIVATE_NESTED'.dup }], visible: 'ok' }
      expected = { 'mode' => 'private', 'secret' => '[FILTERED]', 'string_secret' => '[FILTERED]',
                   'dependent' => '[FILTERED]', 'nested' => [{ 'secret' => '[FILTERED]' }], 'visible' => 'ok' }
      expect(emit_job_parameters(params)).to eq(expected)
      expect(params).to include(secret: 'PRIVATE_SYMBOL', 'string_secret' => 'PRIVATE_STRING',
                                dependent: 'PRIVATE_ROOT', nested: [{ secret: 'PRIVATE_NESTED' }])
      expect(records.to_s).not_to include('PRIVATE_')
    end

    it 'copies root strings before invoking mutating custom filters' do
      filter = proc do |key, value, original|
        original[:root_marker].replace('changed')
        value.replace('[FILTERED]') if key == :secret && value.is_a?(String)
      end
      configure_parameter_filter(filter)
      params = { secret: 'PRIVATE_COPY'.dup, root_marker: 'original'.dup }
      emit_job_parameters(params)
      expect(params).to eq(secret: 'PRIVATE_COPY', root_marker: 'original')
      expect(records.to_s).not_to include('PRIVATE_COPY')
    end

    it 'preserves shared references used by root-sensitive privacy filters' do
      filter = proc do |key, value, original|
        value.replace('[FILTERED]') if key == :secret && original[:first].equal?(original[:second])
      end
      configure_parameter_filter(filter)
      shared = +'private mode'
      params = { secret: +'PRIVATE_ALIAS', first: shared, second: shared }
      expect(emit_job_parameters(params)).to include('secret' => '[FILTERED]')
      expect(records.to_s).not_to include('PRIVATE_ALIAS')
      expect(params[:secret]).to eq('PRIVATE_ALIAS')
      expect(params[:first]).to equal(params[:second])
    end

    it 'preserves frozen policy strings used by root-sensitive privacy filters' do
      filter = proc do |key, value, original|
        value.replace('[FILTERED]') if key == :secret && original[:policy].frozen?
      end
      configure_parameter_filter(filter)
      params = { secret: +'PRIVATE_FROZEN', policy: 'private' }
      expect(emit_job_parameters(params)).to include('secret' => '[FILTERED]')
      expect(records.to_s).not_to include('PRIVATE_FROZEN')
      expect(params[:secret]).to eq('PRIVATE_FROZEN')
      expect(params[:policy]).to be_frozen
    end

    it 'copies string defaults used by original-root filters' do
      filter = proc do |key, value, original|
        original.default.replace('changed')
        value.replace('[FILTERED]') if key == :secret
      end
      configure_parameter_filter(filter)
      params = Hash.new('original'.dup)
      params[:secret] = 'PRIVATE_DEFAULT'.dup
      expect(emit_job_parameters(params)).to eq('secret' => '[FILTERED]')
      expect(params.default).to eq('original')
      expect(params[:secret]).to eq('PRIVATE_DEFAULT')
    end

    it 'redacts unsupported or cyclic trees without inspecting application objects' do
      configure_parameter_filter(proc { |_key, _value| })
      object = Object.new
      object.define_singleton_method(:to_s) { raise 'unsafe inspection' }
      cycle = []
      cycle << cycle
      callable_default = Hash.new { raise 'unsafe default' }
      [object, cycle, callable_default].each do |unsafe|
        records.clear
        params = { secret: 'PRIVATE_UNSAFE', context: unsafe }
        expect(emit_job_parameters(params)).to eq('[FILTERED]')
        expect(records.to_s).not_to include('PRIVATE_UNSAFE')
      end
    end

    it 'redacts an incomplete tree when traversal limits would remove privacy context' do
      filter = proc do |key, value, original|
        value.replace('[FILTERED]') if key == 'secret' && original['private'] == true
      end
      configure_parameter_filter(filter)
      params = { 'secret' => 'PRIVATE_BUDGET', 'context' => Array.new(20) { (1..100).to_a }, 'private' => true }
      expect(emit_job_parameters(params)).to eq('[FILTERED]')
      expect(records.to_s).not_to include('PRIVATE_BUDGET')
    end

    it 'does not truncate values before root-sensitive privacy filters run' do
      filter = proc do |key, value, original|
        value.replace('[FILTERED]') if key == 'secret' && original['context'].end_with?('PRIVATE_SUFFIX')
      end
      configure_parameter_filter([:context, filter])
      context = "#{'a' * 10_000}PRIVATE_SUFFIX"
      emit_job_parameters({ 'secret' => 'PRIVATE_TRUNCATION', 'context' => context })
      expect(records.to_s).not_to include('PRIVATE_TRUNCATION')
      expect(records.to_s).not_to include('a' * 100)
      expect(context).to end_with('PRIVATE_SUFFIX')
    end

    it 'redacts an oversized collection instead of changing the root seen by privacy filters' do
      filter = proc do |key, value, original|
        value.replace('[FILTERED]') if key == 'secret' && original['private'] && value.is_a?(String)
      end
      configure_parameter_filter(filter)
      params = { 'secret' => 'PRIVATE_COLLECTION' }
      99.times { |index| params["visible_#{index}"] = index }
      params['private'] = true
      emit_job_parameters(params)
      expect(records.to_s).not_to include('PRIVATE_COLLECTION')
      expect(params['secret']).to eq('PRIVATE_COLLECTION')
    end
  end

  it 'redacts oversized job argument lists instead of exporting a prefix' do
    install([:active_job])
    job_class = Class.new(ActiveJob::Base) do
      def perform(*)
        :original_result
      end
    end
    stub_const('OversizedArgumentsLogsJob', job_class)
    arguments = Array.new(101) { { visible: 'not a partial argument list' } }
    expect(job_class.new(*arguments).perform_now).to eq(:original_result)
    expect(JSON.parse(records.fetch(0)[:attributes].fetch('rails.job.arguments'))).to eq('[FILTERED]')
  end

  it 'bounds already-filtered controller payloads without inspecting unsafe values' do
    install([:action_controller])
    cycle = []
    cycle << cycle
    unsafe = Object.new
    unsafe.define_singleton_method(:to_s) { raise 'unsafe inspection' }
    [cycle, unsafe, 'a' * 10_001, { password: '[FILTERED]' }.merge((1..101).to_h { |i| [i.to_s, i] })].each do |value|
      notify(params: { password: '[FILTERED]', context: value })
      expect(JSON.parse(records.last[:attributes].fetch('rails.params'))).to eq('[FILTERED]')
    end
    expect(records.size).to eq(4)
  end

  it 'does not reapply custom filters to real controller notification parameters' do
    install([:action_controller])
    filter = proc { |key, value| value.reverse! if key == 'secret' }
    app = double('application', config: double('config', root: nil, filter_parameters: [filter]))
    allow(Rails).to receive(:application).and_return(app)
    controller = Class.new(ActionController::Base) do
      def index
        render plain: 'ok'
      end
    end
    stub_const('OnceFilteredLogsController', controller)
    env = Rack::MockRequest.env_for('/?secret=PRIVATE_ORIGINAL&visible=yes')
    env['action_dispatch.parameter_filter'] = [filter]
    expect(controller.action(:index).call(env).first).to eq(200)
    expect(JSON.parse(records.fetch(0)[:attributes].fetch('rails.params'))).to include(
      'secret' => 'LANIGIRO_ETAVIRP', 'visible' => 'yes'
    )
    expect(records.to_s).not_to include('PRIVATE_ORIGINAL')
  end

  [{}, { wait: 1 }].each do |options|
    it "logs rescued enqueue failures at error severity with options #{options}" do
      install([:active_job], level: :error)
      adapter = Object.new
      def adapter.enqueue(*)
        raise ActiveJob::EnqueueError, 'PRIVATE_ADAPTER_ERROR'
      end

      def adapter.enqueue_at(*)
        raise ActiveJob::EnqueueError, 'PRIVATE_ADAPTER_ERROR'
      end
      job_class = Class.new(ActiveJob::Base) do
        def perform
          :ok
        end
      end
      stub_const('FailedEnqueueLogsJob', job_class)
      job_class.queue_adapter = adapter
      job = job_class.new
      expect(job.enqueue(options)).to be(false)
      expect(job.enqueue_error).to be_a(ActiveJob::EnqueueError)
      expect(records.size).to eq(1)
      expect(records.first[:severity_number]).to eq(17)
      expect(records.first[:attributes]).to include('error.type' => 'ActiveJob::EnqueueError')
      expect(records.to_s).not_to include('PRIVATE_ADAPTER_ERROR')
      expect(job.perform_now).to eq(:ok)
      expect(records.size).to eq(1)
    end
  end

  it 'skips job parameter filters and serialization below the forwarding threshold' do
    install([:active_job], level: :error)
    calls = 0
    filter = proc { |_key, _value| calls += 1 }
    app = double('application', config: double('config', filter_parameters: [filter]))
    allow(Rails).to receive(:application).and_return(app)
    job_class = Class.new(ActiveJob::Base) do
      def perform(*)
        :ok
      end
    end
    stub_const('SuppressedLogsJob', job_class)
    allow(JSON).to receive(:generate).and_call_original
    expect(job_class.new(visible: 'yes').perform_now).to eq(:ok)
    expect(records).to be_empty
    expect(calls).to eq(0)
    expect(JSON).not_to have_received(:generate)
  end

  it 'skips controller parameter traversal and serialization below the forwarding threshold' do
    install([:action_controller], level: :error)
    params = { visible: 'yes' }
    allow(params).to receive(:clone).and_call_original
    allow(JSON).to receive(:generate).and_call_original
    notify(params: params, status: 200)
    expect(records).to be_empty
    expect(params).not_to have_received(:clone)
    expect(JSON).not_to have_received(:generate)
  end

  it 'honors the job argument logging opt-out while retaining lifecycle metadata' do
    install([:active_job])
    app = double('application', config: double('config', filter_parameters: []))
    allow(Rails).to receive(:application).and_return(app)
    job_class = Class.new(ActiveJob::Base) do
      self.log_arguments = false
      def perform(*)
        :ok
      end
    end
    stub_const('PrivateArgumentsLogsJob', job_class)
    job = job_class.new(visible: 'PRIVATE_OPTED_OUT')
    expect(job.perform_now).to eq(:ok)
    expect(records.fetch(0)[:attributes]).to include(
      'rails.job.id' => job.job_id, 'event.name' => 'perform.active_job'
    )
    expect(records.first[:attributes]).not_to have_key('rails.job.arguments')
    expect(records.to_s).not_to include('PRIVATE_OPTED_OUT')
  end

  it 'omits mail delivery job argument wrappers including inherited delivery jobs' do
    install([:active_job])
    app = double('application', config: double('config', filter_parameters: %i[email token]))
    allow(Rails).to receive(:application).and_return(app)
    delivery_job = Class.new(ActiveJob::Base) do
      def perform(*)
        :ok
      end
    end
    stub_const('ActionMailer::MailDeliveryJob', delivery_job)
    stub_const('CustomDeliveryLogsJob', Class.new(delivery_job))
    [delivery_job, CustomDeliveryLogsJob].each do |job_class|
      job = job_class.new('PasswordMailer', 'reset_password', 'deliver_now',
                          args: %w[PRIVATE_EMAIL PRIVATE_RESET_TOKEN])
      expect(job.perform_now).to eq(:ok)
      expect(records.last[:attributes]).to include('rails.job.id' => job.job_id,
                                                   'event.name' => 'perform.active_job')
      expect(records.last[:attributes]).not_to have_key('rails.job.arguments')
    end
    expect(records.to_s).not_to include('PRIVATE_')
  end

  %w[ActionMailer::DeliveryJob ActionMailer::Parameterized::DeliveryJob].each do |class_name|
    it "omits legacy mail payloads from #{class_name}" do
      install([:active_job])
      app = double('application', config: double('config', filter_parameters: []))
      allow(Rails).to receive(:application).and_return(app)
      delivery_job = Class.new(ActiveJob::Base) do
        def perform(*)
          :ok
        end
      end
      stub_const('ActionMailer::DeliveryJob', delivery_job)
      stub_const('ActionMailer::Parameterized::DeliveryJob', Class.new(delivery_job))
      job = class_name.constantize.new(
        'ReceiptMailer', 'receipt', 'deliver_now',
        recipient: 'PRIVATE_RECIPIENT', subject: 'PRIVATE_SUBJECT', body: 'PRIVATE_CONTENT'
      )
      expect(job.perform_now).to eq(:ok)
      expect(records.fetch(0)[:attributes]).to include('rails.job.id' => job.job_id)
      expect(records.first[:attributes]).not_to have_key('rails.job.arguments')
      expect(records.to_s).not_to include('PRIVATE_')
    end
  end

  it 'defaults to no notification subscriptions and retains generic forwarding' do
    expect(config.logs_notifications).to eq([])
    appender = install([])
    notify
    appender.info('ordinary application log')
    expect(records.map { |r| r[:body] }).to eq(['ordinary application log'])
  end

  it 'exports actual controller completion with filtered params and request identity' do
    install([:action_controller])
    controller = Class.new(ActionController::Base) do
      def index
        render plain: 'ok'
      end
    end
    stub_const('StructuredLogsController', controller)
    app = double('application', config: double('config', root: nil, filter_parameters: [:password]))
    allow(Rails).to receive(:application).and_return(app)
    env = Rack::MockRequest.env_for('/?password=secret&visible=yes',
                                    'HTTP_X_POSTHOG_DISTINCT_ID' => 'request-user',
                                    'HTTP_X_POSTHOG_SESSION_ID' => 'request-session')
    env['action_dispatch.parameter_filter'] = [:password]
    middleware = PostHog::Rails::RequestContext.new(controller.action(:index))
    expect(middleware.call(env).first).to eq(200)
    record = records.fetch(0)
    expect(record[:body]).to eq('Rails controller request completed')
    expect(record[:severity_number]).to eq(9)
    expect(record[:attributes]).to include(
      'event.name' => 'process_action.action_controller',
      'rails.controller' => 'StructuredLogsController', 'rails.action' => 'index',
      'http.response.status_code' => 200, 'posthogDistinctId' => 'request-user',
      'sessionId' => 'request-session'
    )
    expect(JSON.parse(record[:attributes].fetch('rails.params'))).to include('password' => '[FILTERED]',
                                                                             'visible' => 'yes')
    expect(PostHog.const_get(:Internal)::Context.current).to be_nil
    expect(records.size).to eq(1)
  end

  it 'allowlists SQL metadata without exporting statements, binds or connection data' do
    install([:active_record])
    load_optional_components
    notify('sql.active_record', name: 'Widget Load', sql: "SELECT * FROM widgets WHERE token='secret'",
                                binds: ['secret'], cached: true, connection: 'secret')
    expect(records.fetch(0)[:attributes]).to eq(
      'event.name' => 'sql.active_record', 'db.operation.name' => 'SELECT',
      'rails.sql.name' => 'Widget Load', 'rails.sql.cached' => true
    )
    expect(records.fetch(0)[:body]).to eq('Rails SQL query completed')
    expect(records.fetch(0)[:severity_number]).to eq(5)
    expect(records.to_s).not_to include('secret')
  end

  it 'filters nested job arguments and omits unkeyed values and exception messages' do
    install([:active_job])
    app = double('application', config: double('config', filter_parameters: [:password]))
    allow(Rails).to receive(:application).and_return(app)
    job_class = Class.new(ActiveJob::Base) do
      def perform(*)
        raise ArgumentError, 'secret failure'
      end
    end
    stub_const('StructuredLogsJob', job_class)
    job = job_class.new('unkeyed-secret', { nested: [{ password: 'secret', visible: 'yes' }] })
    expect { job.perform_now }.to raise_error(ArgumentError, 'secret failure')
    record = records.fetch(0)
    expect(record[:severity_number]).to eq(17)
    expect(record[:attributes]).to include(
      'event.name' => 'perform.active_job', 'rails.job.class' => 'StructuredLogsJob',
      'rails.job.id' => job.job_id, 'rails.job.queue' => 'default', 'error.type' => 'ArgumentError'
    )
    expect(JSON.parse(record[:attributes].fetch('rails.job.arguments'))).to eq(
      ['[FILTERED]', { 'nested' => [{ 'password' => '[FILTERED]', 'visible' => 'yes' }] }]
    )
    expect(records.to_s).not_to include('secret')
    expect(PostHog.const_get(:Internal)::Context.current).to be_nil
  end

  it 'restores existing effective job identity at completion without leaking into later jobs' do
    install([:active_job])
    config.auto_instrument_active_job = true
    ActiveSupport.on_load(:active_job) do
      prepend PostHog::Rails::ActiveJobExtensions unless self < PostHog::Rails::ActiveJobExtensions
    end
    job_class = Class.new(ActiveJob::Base) do
      posthog_distinct_id ->(args) { args[:user_id] }
      def perform(*)
        :ok
      end
    end
    stub_const('StructuredIdentityJob', job_class)
    job = nil
    PostHog.const_get(:Internal)::Context.with_context(distinct_id: 'parent', session_id: 'saved-session') do
      job = job_class.new(user_id: 'effective-user')
      job.serialize
    end
    expect(job.perform_now).to eq(:ok)
    expect(records.last[:attributes]).to include('posthogDistinctId' => 'effective-user',
                                                 'sessionId' => 'saved-session')
    expect(PostHog.const_get(:Internal)::Context.current).to be_nil
    job_class.new({}).perform_now
    expect(records.last[:attributes]).not_to have_key('posthogDistinctId')
    expect(records.last[:attributes]).not_to have_key('sessionId')
    job.arguments = [{ user_id: 'second-user' }]
    job.perform_now
    expect(records.last[:attributes]).to include('posthogDistinctId' => 'second-user')
    config.auto_instrument_active_job = false
    job.perform_now
    expect(records.last[:attributes]).not_to have_key('posthogDistinctId')
  end

  it 'exports mailer lifecycle metadata without recipients, subject or message content' do
    install([:action_mailer])
    load_optional_components
    notify('process.action_mailer', mailer: 'ReceiptMailer', action: 'receipt', args: ['secret'])
    notify('deliver.action_mailer', mailer: 'ReceiptMailer', to: ['secret'], subject: 'secret', mail: 'secret')
    attributes = records.map { |record| record[:attributes] }
    expect(attributes).to eq([
                               { 'event.name' => 'process.action_mailer', 'rails.mailer' => 'ReceiptMailer',
                                 'rails.action' => 'receipt' },
                               { 'event.name' => 'deliver.action_mailer', 'rails.mailer' => 'ReceiptMailer' }
                             ])
    expect(records.to_s).not_to include('secret')
  end

  it 'honors master gate, client gate, shutdown and repeated setup without duplicates' do
    install([:action_controller])
    PostHog::Rails::Logs::Setup.install
    notify
    expect(records.size).to eq(1)
    config.logs_enabled = false
    notify
    config.logs_enabled = true
    PostHog.client = nil
    notify
    expect(records.size).to eq(1)
    PostHog::Rails::Logs::Setup.shutdown
    notify
    expect(records.size).to eq(1)
  end

  it 'shares severity filtering, fail-closed hooks, rate caps and recursion guard with forwarding' do
    config.logs_before_send = proc do |record|
      notify
      raise 'scrubber failed' if record[:attributes]['rails.action'] == 'private'

      record[:attributes]['scrubbed'] = true
      record
    end
    config.logs_max_records_per_minute = 1
    appender = install([:action_controller])
    notify(action: 'private')
    notify(action: 'public')
    appender.info('generic forwarding shares the cap')
    expect(records.size).to eq(2)
    expect(records.first[:attributes]).to include('rails.action' => 'public', 'scrubbed' => true)
    expect(records.last[:body]).to include('rate cap reached')
  end

  it 'filters SQL at the shared severity threshold and gates a disabled client' do
    install([:active_record])
    # Reinstall with the configured threshold, keeping lazy hooks idempotent.
    PostHog::Rails::Logs::Setup.reset
    config.logs_level = :info
    PostHog::Rails::Logs::Setup.remember_client_options(api_key: 'phc_test')
    PostHog::Rails::Logs::Setup.install
    load_optional_components
    notify('sql.active_record', sql: 'SELECT 1')
    expect(records).to be_empty
    notify('sql.active_record', exception: %w[QueryError secret])
    expect(records.last[:severity_number]).to eq(17)
    PostHog.init(api_key: nil, test_mode: true)
    notify('sql.active_record', exception: %w[QueryError secret])
    expect(records.size).to eq(1)
  end

  it 'can disable generic forwarding while preserving notification records' do
    config.logs_forward_rails_logger = false
    install([:action_controller])
    logger = ActiveSupport::Logger.new(File::NULL)
    allow(Rails).to receive(:logger).and_return(logger)
    PostHog::Rails::Railtie.install_posthog_logs
    logger.info('not forwarded')
    notify
    expect(records.map { |record| record[:body] }).to eq(['Rails controller request completed'])
  end

  it 'restores the parent context when a job notification hook fails' do
    config.auto_instrument_active_job = true
    config.logs_before_send = proc { raise 'scrubber failed' }
    install([:active_job])
    job_class = Class.new(ActiveJob::Base)
    job_class.prepend(PostHog::Rails::ActiveJobExtensions) unless job_class < PostHog::Rails::ActiveJobExtensions
    job = job_class.new(user_id: 'job-user')
    PostHog.const_get(:Internal)::Context.with_context(distinct_id: 'parent') do
      notify('perform.active_job', job: job)
      expect(PostHog.const_get(:Internal)::Context.current.distinct_id).to eq('parent')
    end
    expect(PostHog.const_get(:Internal)::Context.current).to be_nil
    expect(records).to be_empty
  end

  it 'guards recursion while application parameter filters run' do
    job = ActiveJob::Base.new(visible: 'original')
    calls = 0
    filter = proc do |_key, _value|
      calls += 1
      notify('perform.active_job', job: job) if calls < 3
    end
    app = double('application', config: double('config', filter_parameters: [filter]))
    allow(Rails).to receive(:application).and_return(app)
    install([:active_job])
    notify('perform.active_job', job: job)
    expect(records.size).to eq(1)
    expect(calls).to eq(1)
  end

  it 'replaces oversized filtered payloads with valid bounded JSON and fails closed on filtering errors' do
    install([:active_job])
    app = double('application', config: double('config', filter_parameters: [:password]))
    allow(Rails).to receive(:application).and_return(app)
    job = ActiveJob::Base.new(first: 'a' * 9000, second: 'b' * 9000, password: 'secret')
    notify('perform.active_job', job: job)
    expect(JSON.parse(records.last[:attributes].fetch('rails.job.arguments'))).to eq(['[FILTERED]'])
    allow(app.config).to receive(:filter_parameters).and_raise('secret')
    job.arguments = [{ password: 'secret' }]
    expect { notify('perform.active_job', job: job) }.not_to raise_error
    expect(records.size).to eq(1)
  end

  it 'bounds traversal of cyclic and repeated parameter values' do
    array_class = Class.new(Array) do
      attr_accessor :visits

      def first(count)
        self.visits += 1
        super
      end
    end
    value = array_class.new
    value.visits = 0
    3.times { value << value }
    app = double('application', config: double('config', filter_parameters: [:password]))
    allow(Rails).to receive(:application).and_return(app)
    install([:action_controller])
    notify(params: { repeated: value, password: 'secret' })
    expect(records.size).to eq(1)
    expect(value.visits).to be <= 1000
    expect(records.to_s).not_to include('secret')
  end

  it 'unsubscribes on reset and reuses load hooks without duplicate records on reinstall' do
    install([:active_record])
    load_optional_components
    notify('sql.active_record', sql: 'SELECT 1')
    PostHog::Rails::Logs::Setup.reset
    notify('sql.active_record', sql: 'SELECT 1')
    install([:active_record])
    load_optional_components
    notify('sql.active_record', sql: 'SELECT 1')
    expect(records.size).to eq(2)
  end

  it 'ignores unknown selections with one bounded diagnostic' do
    logger = instance_spy(Logger)
    PostHog::Logging.logger = logger
    install(%i[unknown unknown])
    load_optional_components
    notify
    expect(records).to be_empty
    expect(logger).to have_received(:warn).with(/logs_notifications/).once
  end

  it 'does not require optional components and waits for real component load hooks in an isolated process' do
    script = <<~RUBY
      require 'posthog'
      require 'rails'
      require 'posthog/rails'
      PostHog::Logging.logger = Logger.new(File::NULL)
      PostHog.init(api_key: 'phc_test', test_mode: true)
      PostHog::Rails.config.logs_enabled = true
      PostHog::Rails.config.logs_notifications = [:active_job, :active_record, :action_mailer]
      records = []
      sink = Object.new
      sink.define_singleton_method(:on_emit) { |**record| records << record }
      PostHog::Rails::Logs::Notifications.install(PostHog::Rails::Logs::Appender.new(sink))
      raise 'eager component load' if defined?(ActiveJob::Base) || defined?(ActiveRecord::Base) || defined?(ActionMailer::Base)
      ActiveSupport::Notifications.instrument('perform.active_job') { :ok }
      ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT 1') { :ok }
      ActiveSupport::Notifications.instrument('deliver.action_mailer', mailer: 'AbsentMailer') { :ok }
      raise 'early subscription' unless records.empty?
      require 'active_job'
      job_class = Class.new(ActiveJob::Base) { def perform; :ok; end }
      Object.const_set(:LazyLogsJob, job_class)
      raise 'changed return' unless job_class.new.perform_now == :ok
      raise 'missing or duplicate log' unless records.size == 1
      PostHog.client.shutdown
    RUBY
    stdout, stderr, status = Open3.capture3('bundle', 'exec', 'ruby', '-Ilib:posthog-rails/lib', '-e', script)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
