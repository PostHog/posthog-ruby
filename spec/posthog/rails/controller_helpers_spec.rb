# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'action_controller'
require 'rack/mock'
require 'open3'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'

RSpec.describe 'controller exception reporting' do
  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }
  let(:error) { StandardError.new('manual failure') }
  let(:arguments) { [error] }
  let(:keywords) { {} }
  let(:controller_class) do
    Class.new(ActionController::API) do
      class << self
        attr_accessor :report_arguments, :report_keywords, :report_result, :after_report, :reported_params
      end

      def self.name
        'ReportsController'
      end

      def create
        self.class.report_result = capture_exception(*self.class.report_arguments, **self.class.report_keywords)
        self.class.after_report&.call
        self.class.reported_params = params.to_unsafe_h
        head :ok
      end

      private

      def current_user
        { 'id' => 'authenticated-user' }
      end
    end
  end

  before(:all) do
    initializer = PostHog::Rails::Railtie.initializers.find { |entry| entry.name == 'posthog.controller_helpers' }
    PostHog::Rails::Railtie.instance.instance_exec(&initializer.block) if initializer
  end

  around do |example|
    previous_config = PostHog::Rails.config
    previous_client = PostHog.client
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Logging.logger = Logger.new(File::NULL)
    PostHog.client = client
    example.run
  ensure
    PostHog.client = previous_client
    PostHog::Rails.config = previous_config
    client.shutdown
  end

  def report(path = '/reports?password=secret&safe=value', headers = {})
    controller_class.report_arguments = arguments
    controller_class.report_keywords = keywords
    app = controller_class.action(:create)
    app = PostHog::Rails::CaptureExceptions.new(app)
    app = PostHog::Rails::RequestContext.new(app)
    app.call(Rack::MockRequest.env_for(path, headers))
  end

  it 'reports handled errors even when automatic capture is off and returns the facade result' do
    response = report

    expect(response.first).to eq(200)
    expect(controller_class.report_result).to be(true)
    event = client.dequeue_last_message
    expect(event[:event]).to eq('$exception')
    expect(event[:distinct_id]).to eq('authenticated-user')
    expect(event[:properties]['$exception_list'].first['mechanism']).to include('type' => 'generic', 'handled' => true)
    expect(event[:properties]).not_to have_key('$exception_source')
  end

  it 'adds Rails-filtered request parameters and safe metadata without changing parameters' do
    application = double('application', config: double('config', filter_parameters: [:password]))
    allow(Rails).to receive(:application).and_return(application)
    report('/reports?password=secret&safe=value', 'HTTP_USER_AGENT' => 'Test Agent')

    properties = client.dequeue_last_message[:properties]
    expect(properties).to include(
      '$request_params' => { 'password' => '[FILTERED]', 'safe' => 'value' },
      '$controller' => 'reports', '$action' => 'create',
      '$request_path' => '/reports', '$request_method' => 'GET', '$user_agent' => 'Test Agent'
    )
    expect(properties['$current_url']).not_to include('secret', '?')
    expect(controller_class.reported_params).to include('password' => 'secret', 'safe' => 'value')
  end

  ['?token=secret#private', '#private'].each do |suffix|
    it "omits sensitive URL suffix #{suffix.inspect} from the helper-derived referrer" do
      report('/reports?token=secret', 'HTTP_REFERER' => "https://example.com/source#{suffix}")
      properties = client.dequeue_last_message[:properties]
      expect(properties['$current_url']).to eq('http://example.org/reports')
      expect(properties['$referrer']).to eq('https://example.com/source')
    end
  end

  it 'uses the configured user resolver and ID method before header identity' do
    PostHog::Rails.config.current_user_resolver = -> { Struct.new(:analytics_id).new('configured-user') }
    PostHog::Rails.config.user_id_method = :analytics_id
    report('/reports', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user')

    expect(client.dequeue_last_message[:distinct_id]).to eq('configured-user')
  end

  it 'uses the configured private current user method' do
    PostHog::Rails.config.current_user_method = :account
    controller_class.class_eval do
      private

      def account
        { 'id' => 'account-user' }
      end
    end
    report
    expect(client.dequeue_last_message[:distinct_id]).to eq('account-user')
  end

  it 'falls back to sanitized request identity and session when user context is disabled' do
    PostHog::Rails.config.capture_user_context = false
    report('/reports', 'HTTP_X_POSTHOG_DISTINCT_ID' => ' header-user ', 'HTTP_X_POSTHOG_SESSION_ID' => ' session-id ')

    event = client.dequeue_last_message
    expect(event[:distinct_id]).to eq('header-user')
    expect(event[:properties]['$session_id']).to eq('session-id')
  end

  it 'falls back to request identity if the user resolver fails' do
    PostHog::Rails.config.current_user_resolver = ->(_controller) { raise 'resolver failed' }
    report('/reports', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user')
    expect(client.dequeue_last_message[:distinct_id]).to eq('header-user')
  end

  it 'honors the tracing header switch and captures personlessly without an identity' do
    PostHog::Rails.config.capture_user_context = false
    PostHog::Rails.config.use_tracing_headers = false
    report('/reports', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user', 'HTTP_X_POSTHOG_SESSION_ID' => 'session-id')

    event = client.dequeue_last_message
    expect(event[:distinct_id]).not_to eq('header-user')
    expect(event[:properties]['$process_person_profile']).to be(false)
    expect(event[:properties]).not_to have_key('$session_id')
  end

  context 'with explicit arguments' do
    let(:properties) do
      { '$controller' => 'explicit-controller', '$request_path' => '/explicit', '$session_id' => 'explicit-session',
        '$referrer' => 'explicit-referrer', '$trace_id' => 'explicit-trace', '$span_id' => 'explicit-span',
        '$request_params' => { 'safe' => 'explicit' }, 'area' => 'checkout' }.freeze
    end
    let(:arguments) { [error, 'explicit-user', properties] }
    let(:flags) do
      record = PostHog::FeatureFlagEvaluations::EvaluatedFlagRecord.new(key: 'checkout', enabled: true)
      PostHog::FeatureFlagEvaluations.new(distinct_id: 'explicit-user', flags: { 'checkout' => record })
    end
    let(:keywords) { { flags: flags, mechanism: { 'type' => 'custom', 'handled' => false } } }

    it 'preserves explicit identity, properties, flags, mechanism, and the input property bag' do
      allow(PostHog).to receive(:capture_exception).and_call_original
      resolved_user = false
      PostHog::Rails.config.current_user_resolver = -> { resolved_user = true }
      report('/reports', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user', 'HTTP_X_POSTHOG_SESSION_ID' => 'header-session')

      event = client.dequeue_last_message
      expect(event[:distinct_id]).to eq('explicit-user')
      expect(resolved_user).to be(false)
      expect(event[:properties]).to include(properties)
      expect(event[:properties]).to include('$feature/checkout' => true, '$active_feature_flags' => ['checkout'])
      expect(event[:properties]['$exception_list'].first['mechanism']).to include('type' => 'custom',
                                                                                  'handled' => false)
      expect(PostHog).to have_received(:capture_exception).with(error, 'explicit-user', hash_including(properties),
                                                                **keywords)
    end
  end

  it 'captures from a full Rails controller as well as API controllers' do
    full_controller = Class.new(ActionController::Base) do
      def self.name
        'FullReportsController'
      end

      def create
        capture_exception(StandardError.new('full controller'))
        head :ok
      end
    end
    full_controller.action(:create).call(Rack::MockRequest.env_for('/full'))
    expect(client.dequeue_last_message[:properties]).to include('$controller' => 'full_reports',
                                                                '$request_path' => '/full')
  end

  it 'falls back to request identity when there is no authenticated user' do
    PostHog::Rails.config.current_user_resolver = ->(_controller) {}
    report('/reports', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user')
    expect(client.dequeue_last_message[:distinct_id]).to eq('header-user')
  end

  it 'captures despite user enrichment failures without replacing application errors or logging secrets' do
    diagnostics = StringIO.new
    PostHog::Logging.logger = Logger.new(diagnostics)
    controller_class.class_eval do
      private

      def current_user
        raise 'PRIVATE_PROBE user lookup failed'
      end
    end
    controller_class.after_report = -> { raise error }
    expect { report }.to(raise_error { |raised| expect(raised).to equal(error) })
    expect(controller_class.report_result).to be(true)
    expect(client.queued_messages).to eq(1)
    expect(diagnostics.string).not_to include('PRIVATE_PROBE')
  end

  context 'with body parameters and completed responses' do
    let(:diagnostics) { StringIO.new }
    let(:parser_calls) { [] }
    let(:controller_class) do
      Class.new(super()) do
        class << self
          attr_accessor :prepare_report, :diagnostics, :helper_diagnostics, :input_positions
        end

        def create
          self.class.prepare_report.call(self)
          diagnostic_offset = self.class.diagnostics.string.length
          input = request.env['rack.input']
          position = input.pos
          self.class.report_result = capture_exception(*self.class.report_arguments, **self.class.report_keywords)
          self.class.input_positions = [position, input.pos]
          self.class.helper_diagnostics = self.class.diagnostics.string[diagnostic_offset..]
          head :ok unless performed?
        end

        def control
          head :ok
        end
      end
    end

    before do
      logger = Logger.new(diagnostics)
      controller_class.logger = logger
      controller_class.diagnostics = diagnostics
      PostHog::Logging.logger = logger
      controller_class.prepare_report = lambda do |controller|
        allow(controller.request).to receive(:request_parameters).and_wrap_original do |original, *args|
          parser_calls << true
          original.call(*args)
        end
      end
    end

    def dispatch_body(body = '', action: :create, query: 'safe=query', headers: {})
      controller_class.report_arguments = arguments
      controller_class.report_keywords = keywords
      env = Rack::MockRequest.env_for("/reports?#{query}", method: 'POST', input: body,
                                                           'CONTENT_TYPE' => 'application/json')
      env.update(headers)
      env['action_dispatch.logger'] = controller_class.logger
      env['action_dispatch.request.path_parameters'] = { id: 'route-id' }
      app = PostHog::Rails::RequestContext.new(
        PostHog::Rails::CaptureExceptions.new(controller_class.action(action))
      )
      [app.call(env), env]
    end

    it 'captures malformed JSON without helper-owned parsing, raw diagnostics, or body position changes' do
      body = '{"token":"PRIVATE_PROBE"'
      dispatch_body(body, action: :control)
      control_logged_body = diagnostics.string.include?('PRIVATE_PROBE')
      diagnostics.truncate(0)
      diagnostics.rewind
      response, = dispatch_body(body)

      expect(response.first).to eq(200)
      expect(controller_class.report_result).to be(true)
      expect(parser_calls).to be_empty
      expect(controller_class.helper_diagnostics).not_to include('PRIVATE_PROBE')
      expect(controller_class.input_positions.uniq.length).to eq(1)
      expect(diagnostics.string.include?('PRIVATE_PROBE')).to eq(control_logged_body)
      event = client.dequeue_last_message
      expect(event[:properties]['$exception_list'].first['value']).to eq(error.message)
      expect(event[:properties]['$request_params']).to include('safe' => 'query', 'id' => 'route-id')
      expect(event[:properties].to_s).not_to include('PRIVATE_PROBE')
    end

    ['action_dispatch.request.parameters', 'action_dispatch.request.request_parameters'].each do |cache_key|
      it "retains filtered valid parameters using the #{cache_key} cache without reparsing or mutation" do
        application = double('application', config: double('config', filter_parameters: [:token]))
        allow(Rails).to receive(:application).and_return(application)
        original_prepare = controller_class.prepare_report
        original_parameters = nil
        controller_class.prepare_report = lambda do |controller|
          original_prepare.call(controller)
          if cache_key.end_with?('request_parameters')
            controller.request.delete_header('action_dispatch.request.parameters')
          end
          original_parameters = controller.request.get_header(cache_key).deep_dup
        end
        response, env = dispatch_body('{"token":"PRIVATE_PROBE","item":"body"}')

        expect(response.first).to eq(200)
        expect(controller_class.report_result).to be(true)
        expect(parser_calls).to be_empty
        expect(controller_class.input_positions.uniq.length).to eq(1)
        expect(env[cache_key]).to eq(original_parameters)
        expect(env[cache_key]['token']).to eq('PRIVATE_PROBE')
        expect(client.dequeue_last_message[:properties]['$request_params']).to include(
          'token' => '[FILTERED]', 'item' => 'body', 'safe' => 'query', 'id' => 'route-id'
        )
      end
    end

    ['action_dispatch.request.parameters', 'action_dispatch.request.request_parameters', nil]
      .product(%i[public private]).each do |cache_key, visibility|
      it "honors #{visibility} request-specific parameter filters with #{cache_key || 'an uncached body'}" do
        application = double('application', config: double('config', filter_parameters: [:password]))
        allow(Rails).to receive(:application).and_return(application)
        original_prepare = controller_class.prepare_report
        original_parameters = nil
        controller_class.prepare_report = lambda do |controller|
          original_prepare.call(controller)
          controller.request.singleton_class.send(visibility, :parameter_filter)
          expect(controller.request.respond_to?(:parameter_filter)).to eq(visibility == :public)
          controller.request.delete_header('action_dispatch.request.parameters') unless
            cache_key == 'action_dispatch.request.parameters'
          controller.request.delete_header('action_dispatch.request.request_parameters') unless cache_key
          original_parameters = controller.request.get_header(cache_key).deep_dup if cache_key
        end
        response, env = dispatch_body(
          '{"person":{"ssn":"PRIVATE_BODY"},"item":"body"}',
          query: 'ssn=PRIVATE_QUERY&password=PRIVATE_PASSWORD&safe=query',
          headers: { 'action_dispatch.parameter_filter' => %i[password ssn] }
        )

        expect(response.first).to eq(200)
        expect(controller_class.report_result).to be(true)
        expect(parser_calls).to be_empty
        expect(controller_class.input_positions.uniq.length).to eq(1)
        expect(env[cache_key]).to eq(original_parameters) if cache_key
        properties = client.dequeue_last_message[:properties]
        expect(properties['$request_params']).to include(
          'ssn' => '[FILTERED]', 'password' => '[FILTERED]', 'safe' => 'query'
        )
        if cache_key
          expect(properties['$request_params']).to include('person' => { 'ssn' => '[FILTERED]' }, 'item' => 'body')
        end
        expect(properties['$request_params'].to_s).not_to include('PRIVATE_')
        expect(env).not_to have_key('action_dispatch.request.request_parameters') unless cache_key
      end
    end

    it 'does not proactively parse a valid uncached body' do
      original_prepare = controller_class.prepare_report
      controller_class.prepare_report = lambda do |controller|
        original_prepare.call(controller)
        controller.request.delete_header('action_dispatch.request.parameters')
        controller.request.delete_header('action_dispatch.request.request_parameters')
      end
      _, env = dispatch_body('{"token":"PRIVATE_PROBE","item":"body"}')

      expect(controller_class.report_result).to be(true)
      expect(parser_calls).to be_empty
      expect(env).not_to have_key('action_dispatch.request.request_parameters')
      expect(client.dequeue_last_message[:properties]['$request_params']).to eq('safe' => 'query', 'id' => 'route-id')
      expect(controller_class.input_positions.uniq.length).to eq(1)
    end

    it 'still captures when a configured parameter filter fails without logging its sensitive error' do
      filter = ->(_key, _value) { raise 'PRIVATE_PROBE filter failed' }
      application = double('application', config: double('config', filter_parameters: [filter]))
      allow(Rails).to receive(:application).and_return(application)
      dispatch_body('{"token":"PRIVATE_PROBE"}')

      expect(controller_class.report_result).to be(true)
      expect(controller_class.helper_diagnostics).not_to include('PRIVATE_PROBE')
      properties = client.dequeue_last_message[:properties]
      expect(properties['$exception_list'].first['value']).to eq(error.message)
      expect(properties).not_to have_key('$request_params')
    end

    it 'still captures when request URL metadata has invalid encoding' do
      controller_class.prepare_report = lambda do |controller|
        controller.request.set_header('HTTP_REFERER', "\xFF")
      end
      dispatch_body
      expect(controller_class.report_result).to be(true)
      expect(client.dequeue_last_message[:properties]).not_to have_key('$referrer')
    end

    it 'does not log a failing configured user resolver message' do
      PostHog::Rails.config.current_user_resolver = -> { raise 'PRIVATE_PROBE resolver failed' }
      dispatch_body
      expect(controller_class.report_result).to be(true)
      expect(controller_class.helper_diagnostics).not_to include('PRIVATE_PROBE')
      expect(client.queued_messages).to eq(1)
    end

    it 'leaves automatic middleware collection of uncached body parameters unchanged' do
      PostHog::Rails.config.auto_capture_exceptions = true
      application = double('application', config: double('config', filter_parameters: [:token]))
      allow(Rails).to receive(:application).and_return(application)
      env = Rack::MockRequest.env_for('/automatic?safe=query', method: 'POST',
                                                               input: '{"token":"PRIVATE_PROBE","item":"body"}',
                                                               'CONTENT_TYPE' => 'application/json')
      allow(Rails).to receive(:root).and_return(nil)
      middleware = PostHog::Rails::CaptureExceptions.new(->(_env) { raise error })

      expect { middleware.call(env) }.to(raise_error { |raised| expect(raised).to equal(error) })
      expect(client.dequeue_last_message[:properties]['$request_params']).to include(
        'token' => '[FILTERED]', 'item' => 'body', 'safe' => 'query'
      )
    end

    it 'includes a response status already performed by the controller' do
      original_prepare = controller_class.prepare_report
      controller_class.prepare_report = lambda do |controller|
        original_prepare.call(controller)
        controller.head :unprocessable_entity
      end
      response, = dispatch_body

      expect(response.first).to eq(422)
      expect(client.dequeue_last_message[:properties]['$response_status_code']).to eq(422)
    end

    it 'does not invent the default status before the controller performs a response' do
      response, = dispatch_body
      expect(response.first).to eq(200)
      expect(client.dequeue_last_message[:properties]).not_to have_key('$response_status_code')
    end

    context 'with an explicit response status property' do
      let(:arguments) { [error, nil, { '$response_status_code' => 409 }] }

      it 'keeps explicit status precedence over a performed response' do
        controller_class.prepare_report = ->(controller) { controller.head :unprocessable_entity }
        response, = dispatch_body
        expect(response.first).to eq(422)
        expect(client.dequeue_last_message[:properties]['$response_status_code']).to eq(409)
      end
    end

    it 'does not log sensitive error messages when the facade raises' do
      allow(PostHog).to receive(:capture_exception).and_raise(StandardError, 'PRIVATE_PROBE capture failed')
      dispatch_body
      expect(controller_class.report_result).to be(false)
      expect(controller_class.helper_diagnostics).not_to include('PRIVATE_PROBE')
      expect(client.queued_messages).to eq(0)
    end
  end

  it 'derives trace IDs from an active optional OpenTelemetry span' do
    begin
      require 'opentelemetry-api'
    rescue LoadError
      skip 'Install the optional bundle to test active span correlation'
    end
    span_context = OpenTelemetry::Trace::SpanContext.new(
      trace_id: ['00000000000000000000000000000001'].pack('H*'),
      span_id: ['0000000000000002'].pack('H*')
    )
    span = OpenTelemetry::Trace.non_recording_span(span_context)
    OpenTelemetry::Trace.with_span(span) { report }
    expect(client.dequeue_last_message[:properties]).to include(
      '$trace_id' => '00000000000000000000000000000001', '$span_id' => '0000000000000002'
    )
  end

  it 'does not apply automatic exception exclusions to manual reports' do
    PostHog::Rails.config.excluded_exceptions = ['StandardError']
    report
    expect(client.queued_messages).to eq(1)
  end

  it 'preserves deduplication when the manually reported error escapes the controller' do
    PostHog::Rails.config.auto_capture_exceptions = true
    controller_class.after_report = -> { raise error }

    expect { report }.to(raise_error { |raised| expect(raised).to equal(error) })
    expect(client.queued_messages).to eq(1)
  end

  it 'returns false for a previously captured exception' do
    client.capture_exception(error)
    report
    expect(controller_class.report_result).to be(false)
    expect(client.queued_messages).to eq(1)
  end

  context 'with an unsupported exception input' do
    let(:arguments) { [nil, nil, nil] }

    it 'preserves the nil core result and accepts nil additional properties' do
      report
      expect(controller_class.report_result).to be_nil
      expect(client.queued_messages).to eq(0)
    end
  end

  it 'preserves false when before_send drops the report' do
    PostHog.client = PostHog::Client.new(api_key: API_KEY, test_mode: true, before_send: ->(_event) {})
    report
    expect(controller_class.report_result).to be(false)
    expect(PostHog.client.queued_messages).to eq(0)
  ensure
    PostHog.client.shutdown
  end

  it 'does not resolve users or enqueue events with a disabled client' do
    PostHog.client = PostHog::Client.new(api_key: nil, silence_disabled_client_error: true)
    resolved_user = false
    PostHog::Rails.config.current_user_resolver = -> { resolved_user = true }
    report
    expect(resolved_user).to be(false)
    expect(controller_class.report_result).to be(false)
    expect(PostHog.client.queued_messages).to eq(0)
  ensure
    PostHog.client.shutdown
  end

  it 'does not create a client when reporting before initialization' do
    PostHog.client = nil
    expect(PostHog::Client).not_to receive(:new)
    report
    expect(controller_class.report_result).to be(false)
    expect(PostHog.client).to be_nil
  end

  it 'does not leak controller user or request context to subsequent captures' do
    report('/first', 'HTTP_X_POSTHOG_SESSION_ID' => 'first-session')
    client.dequeue_last_message
    client.capture_exception(StandardError.new('outside'))
    event = client.dequeue_last_message
    expect(event[:distinct_id]).not_to eq('authenticated-user')
    expect(event[:properties]).not_to have_key('$session_id')
    expect(event[:properties]).not_to have_key('$request_path')
    expect(event[:properties]).not_to have_key('$request_params')
  end

  it 'keeps the helper private and out of controller actions' do
    expect(controller_class.private_method_defined?(:capture_exception)).to be(true)
    expect(controller_class.instance_method(:capture_exception).parameters).to eq(
      [%i[req exception], %i[opt distinct_id], %i[opt additional_properties], %i[key flags], %i[key mechanism]]
    )
    expect(controller_class.action_methods).not_to include('capture_exception')
    expect(ActionController::Base.private_method_defined?(:capture_exception)).to be(true)
    expect(ActionController::Base.action_methods).not_to include('capture_exception')
  end

  it 'does not override application methods' do
    controller_class.class_eval do
      private

      def capture_exception(*)
        :application_result
      end
    end
    report
    expect(controller_class.report_result).to eq(:application_result)
    expect(client.queued_messages).to eq(0)
  end

  it 'does not override inherited helpers installed before Rails initialization' do
    script = <<~RUBY
      require 'posthog'
      require 'rails'
      require 'action_controller/railtie'
      require 'posthog/rails'
      existing_helpers = Module.new do
        private
        def capture_exception(*)
          :existing
        end
      end
      [ActionController::Base, ActionController::API].each { |controller| controller.include(existing_helpers) }
      class ExistingHelperApp < Rails::Application
        config.eager_load = false
        config.secret_key_base = 'test-secret'
        config.logger = Logger.new(File::NULL)
      end
      ExistingHelperApp.initialize!
      [ActionController::Base, ActionController::API].each do |controller|
        abort 'overrode existing helper' unless controller.new.send(:capture_exception, StandardError.new) == :existing
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib', '-e', script)
    expect(status).to be_success, "#{stdout}\n#{stderr}"
  end

  it 'installs lazily during real Rails boot without loading optional controllers' do
    script = <<~RUBY
      require 'posthog'
      require 'rails'
      require 'posthog/rails'
      abort 'loaded controllers eagerly' if defined?(ActionController::Base) || defined?(ActionController::API)
      require 'action_controller/railtie'
      class HelperApp < Rails::Application
        config.eager_load = false
        config.secret_key_base = 'test-secret'
        config.logger = Logger.new(File::NULL)
      end
      HelperApp.initialize!
      require 'action_controller'
      [ActionController::Base, ActionController::API].each do |controller|
        abort 'missing private helper' unless controller.private_method_defined?(:capture_exception)
        abort 'helper is an action' if controller.action_methods.include?('capture_exception')
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib', '-e', script)
    expect(status).to be_success, "#{stdout}\n#{stderr}"
  end
end
