# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'rails/railtie'
require 'action_dispatch'
require 'active_job'
require 'active_support/execution_context'
require 'rack/mock'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'

RSpec.describe 'Rails exception context' do
  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }
  let(:error) { StandardError.new('application failure') }

  around do |example|
    previous_config = PostHog::Rails.config
    previous_context = ActiveSupport::ExecutionContext.to_h
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails.config.auto_capture_exceptions = true
    ActiveSupport::ExecutionContext.clear
    example.run
  ensure
    ActiveSupport::ExecutionContext.clear
    ActiveSupport::ExecutionContext.set(**previous_context)
    PostHog::Rails.config = previous_config
    client.shutdown
  end

  before do
    allow(PostHog).to receive(:client).and_return(client)
    allow(Rails).to receive(:application).and_return(
      double('application',
             config: double('config', root: nil, filter_parameters: [:password, :token, /authorization/i]))
    )
  end

  def request_env(body = '', content_type = 'application/json')
    Rack::MockRequest.env_for('/orders?query=visible', method: 'POST', input: body,
                                                       'CONTENT_TYPE' => content_type,
                                                       'HTTP_AUTHORIZATION' => 'secret-token',
                                                       'HTTP_X_REGION' => 'eu',
                                                       'HTTP_COOKIE' => 'locale=en; token=private; other=hidden')
  end

  def capture_request(env, expected_error: error, &block)
    app = block || ->(_env) { raise expected_error }
    middleware = PostHog::Rails::RequestContext.new(PostHog::Rails::CaptureExceptions.new(app))
    expect { middleware.call(env) }.to raise_error(expected_error)
    client.dequeue_last_message&.fetch(:properties)
  end

  def enable_sensitive_context
    PostHog::Rails.config.exception_request_headers = %w[X-Region Authorization]
    PostHog::Rails.config.exception_request_cookies = %w[locale token]
    PostHog::Rails.config.exception_request_body = true
  end

  it 'disables new sensitive collection by default and preserves filtered request params' do
    properties = capture_request(request_env('{"item":"book","password":"private"}'))
    expect(properties.keys).not_to include('$request_headers', '$request_cookies', '$request_body')
    expect(properties['$request_params']).to include('item' => 'book', 'password' => '[FILTERED]')
  end

  it 'captures only allowlisted and filtered headers/cookies and structured JSON' do
    enable_sensitive_context
    properties = capture_request(request_env('{"item":"book","password":"private","nested":{"token":"private"}}'))
    expect(properties['$request_headers']).to eq('x-region' => 'eu', 'authorization' => '[FILTERED]')
    expect(properties['$request_cookies']).to eq('locale' => 'en', 'token' => '[FILTERED]')
    expect(properties['$request_body']).to eq('item' => 'book', 'password' => '[FILTERED]',
                                              'nested' => { 'token' => '[FILTERED]' })
  end

  it 'filters form bodies without changing the input position' do
    enable_sensitive_context
    env = request_env('item=book&password=private', 'application/x-www-form-urlencoded')
    env['rack.input'].pos = 4
    properties = capture_request(env)
    expect(properties['$request_body']).to eq('item' => 'book', 'password' => '[FILTERED]')
    expect(env['rack.input'].pos).to eq(4)
  end

  it 'preserves downstream body reads and the original exception' do
    enable_sensitive_context
    body = '{"item":"book"}'
    env = request_env(body)
    properties = capture_request(env) do |rack_env|
      expect(rack_env['rack.input'].read).to eq(body)
      raise error
    end
    expect(properties['$request_body']).to eq('item' => 'book')
    expect(env['rack.input'].pos).to eq(body.bytesize)
  end

  ['{bad json', '{"password":"private"'].each do |body|
    it "still captures the original exception for malformed JSON of #{body.bytesize} bytes" do
      enable_sensitive_context
      env = request_env(body)
      diagnostics = StringIO.new
      env['action_dispatch.logger'] = Logger.new(diagnostics)
      properties = nil
      expect { properties = capture_request(env) }.not_to output.to_stderr
      expect(diagnostics.string).not_to include(body)
      expect(properties).to include('$exception_list')
      expect(properties).not_to have_key('$request_body')
      expect(env['rack.input'].pos).to eq(0)
    end
  end

  it 'never reads streaming inputs, but preserves cached body and query params' do
    enable_sensitive_context
    env = request_env
    input = double('stream')
    expect(input).not_to receive(:read)
    env['rack.input'] = input
    env['action_dispatch.request.request_parameters'] = { 'item' => 'cached', 'password' => 'private' }
    properties = capture_request(env)
    expect(properties).not_to have_key('$request_body')
    expect(properties['$request_params']).to include('query' => 'visible', 'item' => 'cached',
                                                     'password' => '[FILTERED]')
  end

  it 'does not read oversized input for the new body property' do
    enable_sensitive_context
    env = request_env('x' * 10_001)
    expect(env['rack.input']).not_to receive(:read)
    properties = capture_request(env)
    expect(properties).not_to have_key('$request_body')
    expect(env['rack.input'].pos).to eq(0)
  end

  %w[text/plain multipart/form-data].each do |type|
    it "does not capture #{type} bodies in the new body property" do
      enable_sensitive_context
      env = request_env('private raw text', type)
      expect(env['rack.input']).not_to receive(:read)
      properties = capture_request(env)
      expect(properties).not_to have_key('$request_body')
    end
  end

  it 'does not attach sensitive properties or execution context to analytics events' do
    enable_sensitive_context
    env = request_env('{"item":"book"}')
    properties = capture_request(env) do |_rack_env|
      ActiveSupport::ExecutionContext[:operation] = 'exceptions only'
      client.capture(event: 'ordinary')
      raise error
    end
    expect(properties.keys).not_to include('$request_headers', '$request_cookies', '$request_body',
                                           '$execution_context')
  end

  it 'snapshots and filters execution context on request exceptions without retaining it' do
    context = { 'label' => +'original', 'password' => 'private' }
    ActiveSupport::ExecutionContext.set(operation: context) do
      properties = capture_request(request_env)
      context['label'].replace('changed')
      expect(properties['$execution_context']).to eq('operation' => { 'label' => 'original',
                                                                      'password' => '[FILTERED]' })
    end
    properties = capture_request(request_env, expected_error: StandardError.new('next request'))
    expect(properties.fetch('$execution_context', {}).compact).to be_empty
  end

  it 'enriches actual ActiveJob failures with filtered execution context' do
    PostHog::Rails.config.auto_instrument_active_job = true
    stub_const('ExceptionContextJob', Class.new(ActiveJob::Base) do
      prepend PostHog::Rails::ActiveJobExtensions

      def perform
        raise 'job failure'
      end
    end)
    ExceptionContextJob.logger = Logger.new(File::NULL)
    ActiveSupport::ExecutionContext.set(operation: { password: 'private', region: 'eu' }) do
      expect { ExceptionContextJob.perform_now }.to raise_error('job failure')
    end
    properties = client.dequeue_last_message[:properties]
    expect(properties['$execution_context']).to include('operation' => { 'password' => '[FILTERED]', 'region' => 'eu' })
  end

  it 'filters reporter metadata and enriches actual Rails error reports' do
    reporter = ActiveSupport::ErrorReporter.new
    reporter.subscribe(PostHog::Rails::ErrorSubscriber.new)
    ActiveSupport::ExecutionContext.set(operation: { token: 'private' }) do
      reporter.handle(context: { token: 'private', details: { password: 'private' } }) { raise error }
    end
    properties = client.dequeue_last_message[:properties]
    expect(properties).to include('$context_token' => '[FILTERED]',
                                  '$context_details' => { 'password' => '[FILTERED]' })
    expect(properties['$execution_context']).to include('operation' => { 'token' => '[FILTERED]' })
  end

  it 'serializes GlobalID-capable metadata without serializing model attributes' do
    model = double('record', to_global_id: 'gid://app/Order/42')
    expect(model).not_to receive(:to_hash)
    ActiveSupport::ExecutionContext[:record] = model
    properties = capture_request(request_env)
    expect(properties['$execution_context']).to eq('record' => 'gid://app/Order/42')
  end

  it 'uses a class marker when GlobalID serialization raises without logging the error message' do
    stub_const('FailingGlobalIdRecord', Class.new do
      def to_global_id
        raise 'private serialization secret'
      end
    end)
    ActiveSupport::ExecutionContext[:record] = FailingGlobalIdRecord.new
    logger_output = StringIO.new
    PostHog::Logging.logger = Logger.new(logger_output)
    properties = capture_request(request_env)
    expect(properties['$execution_context']).to eq('record' => '[FailingGlobalIdRecord]')
    expect(logger_output.string).not_to include('private serialization secret')
  end

  it 'preserves legacy form params without enabling new body collection' do
    env = request_env('item=book&password=private', 'application/x-www-form-urlencoded')
    properties = capture_request(env)
    expect(properties['$request_params']).to include('item' => 'book', 'password' => '[FILTERED]')
    expect(properties).not_to have_key('$request_body')
    expect(env['rack.input'].pos).to eq(0)
  end

  it 'rejects oversized cached parameters without mutating their values' do
    env = request_env('uncached multipart bytes', 'multipart/form-data')
    env['action_dispatch.request.request_parameters'] =
      { 'item' => 'x' * 12_000, 'query' => 'body', 'password' => 'private' }
    env['action_dispatch.request.path_parameters'] = { 'query' => 'path' }
    properties = capture_request(env)
    expect(properties['$request_params']).to eq({})
    expect(env['action_dispatch.request.request_parameters']['item'].length).to eq(12_000)
    expect(env['rack.input'].pos).to eq(0)
  end

  it 'omits uncached oversized bodies without reading or losing query params' do
    enable_sensitive_context
    env = request_env("{#{' ' * 12_000}}")
    expect(env['rack.input']).not_to receive(:read)
    properties = capture_request(env)
    expect(properties['$request_params']).to eq('query' => 'visible')
    expect(properties).not_to have_key('$request_body')
  end

  it 'bounds reads even when content length understates body size' do
    enable_sensitive_context
    env = request_env("{#{' ' * 12_000}}")
    env['CONTENT_LENGTH'] = '2'
    properties = capture_request(env)
    expect(properties['$request_params']).to eq('query' => 'visible')
    expect(properties).not_to have_key('$request_body')
    expect(env['rack.input'].pos).to eq(0)
  end

  it 'never reads input whose seek capability raises' do
    enable_sensitive_context
    env = request_env
    input = double('pipe', pos: 0)
    allow(input).to receive(:seek).and_raise(IOError, 'not seekable')
    expect(input).not_to receive(:read)
    env['rack.input'] = input
    expect(capture_request(env)['$request_params']).to eq('query' => 'visible')
  end

  it 'never exposes the entire Cookie header even if it is allowlisted as a header' do
    PostHog::Rails.config.exception_request_headers = %w[Cookie HTTP_COOKIE Set-Cookie]
    properties = capture_request(request_env)
    expect(properties).not_to have_key('$request_headers')
  end

  it 'applies dotted and proc Rails filters to bodies before sending' do
    enable_sensitive_context
    filters = ['user.email', proc { |key, value| value.replace('[CUSTOM]') if key == 'custom' && value.is_a?(String) }]
    allow(Rails.application.config).to receive(:filter_parameters).and_return(filters)
    properties = capture_request(request_env('{"user":{"email":"private"},"custom":"private"}'))
    expect(properties['$request_body']).to eq('user' => { 'email' => '[FILTERED]' }, 'custom' => '[CUSTOM]')
  end

  it 'keeps the response and handles Rails-stored exceptions without changing input' do
    enable_sensitive_context
    env = request_env('{"item":"book"}')
    response = [500, {}, ['failed']]
    app = lambda do |rack_env|
      rack_env['action_dispatch.exception'] = error
      response
    end
    expect(PostHog::Rails::CaptureExceptions.new(app).call(env)).to equal(response)
    expect(client.dequeue_last_message[:properties]['$request_body']).to eq('item' => 'book')
    expect(env['rack.input'].pos).to eq(0)
  end

  it 'skips sensitive reads when the client is disabled or absent' do
    enable_sensitive_context
    [nil, PostHog::Client.new(api_key: nil, test_mode: true)].each do |owner|
      allow(PostHog).to receive(:client).and_return(owner)
      env = request_env('{"item":"book"}')
      expect(env['rack.input']).not_to receive(:read)
      expect { PostHog::Rails::CaptureExceptions.new(->(_env) { raise error }).call(env) }.to raise_error(error)
    ensure
      owner&.shutdown
    end
    expect(client.queued_messages).to eq(0)
  end

  it 'keeps exception capture switches authoritative' do
    enable_sensitive_context
    PostHog::Rails.config.auto_capture_exceptions = false
    env = request_env('{"item":"book"}')
    expect(env['rack.input']).not_to receive(:read)
    expect { PostHog::Rails::CaptureExceptions.new(->(_env) { raise error }).call(env) }.to raise_error(error)
    expect(client.queued_messages).to eq(0)
  end

  it 'still captures when Rails filters fail without leaking diagnostics' do
    enable_sensitive_context
    allow(Rails.application.config).to receive(:filter_parameters).and_raise('secret filter failure')
    diagnostics = StringIO.new
    PostHog::Logging.logger = Logger.new(diagnostics)
    properties = capture_request(request_env('{"password":"private"}'))
    expect(properties['$request_body']).to eq({})
    expect(diagnostics.string).not_to include('secret filter failure', 'private')
  end

  it 'supports Rails versions without ExecutionContext' do
    original = ActiveSupport.send(:remove_const, :ExecutionContext)
    properties = capture_request(request_env)
    expect(properties).not_to have_key('$execution_context')
  ensure
    ActiveSupport.const_set(:ExecutionContext, original)
  end

  it 'keeps unknown objects and non-finite numbers JSON-safe without exposing object strings' do
    secret_object = Object.new
    def secret_object.to_s
      'private model attributes'
    end
    ActiveSupport::ExecutionContext.set(record: secret_object, number: Float::INFINITY) do
      properties = capture_request(request_env)
      expect(properties['$execution_context']).to eq('record' => '[Object]', 'number' => 'Infinity')
      expect(JSON.generate(properties['$execution_context'])).not_to include('private model attributes')
    end
  end

  it 'rejects deep metadata as a whole' do
    deep = 20.times.reduce('leaf') { |value, _| { 'nested' => value } }
    ActiveSupport::ExecutionContext.set(deep: deep) do
      properties = capture_request(request_env)
      expect(properties).not_to have_key('$execution_context')
    end
  end

  it 'does not forward sensitive exception data through the Rails log appender' do
    enable_sensitive_context
    sink = double('log sink')
    emitted = []
    allow(sink).to receive(:on_emit) { |**record| emitted << record }
    appender = PostHog::Rails::Logs::Appender.new(sink)
    capture_request(request_env('{"password":"private"}')) do |_env|
      appender.info('ordinary log')
      raise error
    end
    expect(emitted.length).to eq(1)
    expect(JSON.generate(emitted)).not_to include('private', 'secret-token', 'request_body', 'request_cookies',
                                                  'request_headers')
  end

  it 'supports real GlobalID objects in nested reporter metadata and job arguments' do
    stub_const('ExceptionContextRecord', Class.new do
      include GlobalID::Identification

      def id
        42
      end

      def to_global_id
        super(app: 'test')
      end

      def as_json(*)
        raise 'must not serialize attributes'
      end
    end)
    record = ExceptionContextRecord.new
    reporter = ActiveSupport::ErrorReporter.new
    reporter.subscribe(PostHog::Rails::ErrorSubscriber.new)
    reporter.handle(context: { record: record }) { raise error }
    expect(client.dequeue_last_message[:properties]['$context_record']).to eq('gid://test/ExceptionContextRecord/42')

    PostHog::Rails.config.auto_instrument_active_job = true
    stub_const('GlobalIdExceptionContextJob', Class.new(ActiveJob::Base) do
      prepend PostHog::Rails::ActiveJobExtensions

      def perform(*)
        raise 'job failure'
      end
    end)
    GlobalIdExceptionContextJob.logger = Logger.new(File::NULL)
    expect do
      GlobalIdExceptionContextJob.perform_now({ record: record, password: 'private' })
    end.to raise_error('job failure')
    expect(client.dequeue_last_message[:properties]['$job_arguments']).to eq(
      [{ 'record' => 'gid://test/ExceptionContextRecord/42', 'password' => '[FILTERED]' }]
    )
  end

  it 'preserves already merged Rails parameters for unsafe inputs' do
    env = request_env
    env['rack.input'] = double('stream')
    env['action_dispatch.request.parameters'] = { 'cached' => 'value', 'password' => 'private' }
    expect(capture_request(env)['$request_params']).to eq('cached' => 'value', 'password' => '[FILTERED]')
  end

  it 'isolates ExecutionContext snapshots across concurrent request failures' do
    threads = %w[first second].map do |label|
      Thread.new do
        ActiveSupport::ExecutionContext.set(label: label) do
          middleware = PostHog::Rails::CaptureExceptions.new(->(_env) { raise label })
          begin
            middleware.call(request_env)
          rescue RuntimeError
            nil
          end
        end
      ensure
        ActiveSupport::ExecutionContext.clear
      end
    end
    threads.each(&:value)
    contexts = 2.times.map { client.dequeue_last_message[:properties]['$execution_context'] }
    expect(contexts).to contain_exactly({ 'label' => 'first' }, { 'label' => 'second' })
    expect(ActiveSupport::ExecutionContext.to_h).to be_empty
  end

  describe 'custom Rails filter semantics' do
    let(:filter_job) do
      stub_const('FilterSemanticsExceptionJob', Class.new(ActiveJob::Base) do
        prepend PostHog::Rails::ActiveJobExtensions

        def perform(*)
          raise 'filtered job failure'
        end
      end)
      FilterSemanticsExceptionJob.logger = Logger.new(File::NULL)
      FilterSemanticsExceptionJob
    end

    def use_filters(*filters)
      allow(Rails.application.config).to receive(:filter_parameters).and_return(filters)
    end

    it 'preserves symbol and string keys for actual job exception argument filters' do
      PostHog::Rails.config.auto_instrument_active_job = true
      filter = proc do |key, value|
        value.replace('[FILTERED]') if %i[secret].include?(key) && value.is_a?(String)
        value.replace('[STRING FILTERED]') if key == 'secret' && value.is_a?(String)
      end
      use_filters(filter)
      arguments = { symbols: { secret: 'PRIVATE_SYMBOL' }, strings: { 'secret' => 'PRIVATE_STRING' } }
      native = ActiveSupport::ParameterFilter.new([filter]).filter(arguments)
      expect(native[:symbols][:secret]).to eq('[FILTERED]')
      expect(native[:strings]['secret']).to eq('[STRING FILTERED]')

      expect { filter_job.perform_now(arguments) }.to raise_error('filtered job failure')
      properties = client.dequeue_last_message[:properties]
      expect(properties['$job_arguments']).to eq(
        [{ 'symbols' => { 'secret' => '[FILTERED]' }, 'strings' => { 'secret' => '[STRING FILTERED]' } }]
      )
      expect(arguments[:symbols][:secret]).to eq('PRIVATE_SYMBOL')
      expect(arguments[:strings]['secret']).to eq('PRIVATE_STRING')
    end

    it 'preserves symbol keys and root value types for ExecutionContext custom filters' do
      filter = proc do |key, value, original|
        if key == :secret && original[:kind] == :private && original[:created_at].is_a?(Time)
          value.replace('[FILTERED]')
        end
      end
      use_filters(filter)
      context = { secret: 'PRIVATE_CONTEXT', kind: :private, created_at: Time.utc(2026, 1, 1) }
      ActiveSupport::ExecutionContext.set(**context) do
        properties = capture_request(request_env)
        expect(properties['$execution_context']['secret']).to eq('[FILTERED]')
      end
      expect(context[:secret]).to eq('PRIVATE_CONTEXT')
    end

    it 'preserves scalar types seen by Rails filters before GlobalID-aware normalization' do
      record = Class.new do
        def to_global_id
          'gid://app/Order/42'
        end
      end.new
      filter = proc do |key, value, original|
        if key == :secret && original[:record].respond_to?(:to_global_id) && original[:number].infinite?
          value.replace('[FILTERED]')
        end
      end
      use_filters(filter)
      ActiveSupport::ExecutionContext.set(secret: 'PRIVATE_TYPES', record: record, number: Float::INFINITY) do
        properties = capture_request(request_env)
        expect(properties['$execution_context']).to include('secret' => '[FILTERED]', 'record' => 'gid://app/Order/42')
      end
    end

    [' PRIVATE_HEADER ', "PRIVATE_HEADER#{'x' * 1_100}MASK"].each do |header|
      it "filters original header values without normalization for #{header.bytesize} bytes" do
        enable_sensitive_context
        PostHog::Rails.config.exception_request_headers = ['X-Region']
        filter = proc { |key, value| value.replace('[FILTERED]') if key == 'x-region' && value == header }
        use_filters(filter)
        env = request_env
        env['HTTP_X_REGION'] = header
        properties = capture_request(env)
        expect(properties['$request_headers']).to eq('x-region' => '[FILTERED]')
        expect(env['HTTP_X_REGION']).to eq(header)
      end
    end

    ['application/json', 'application/x-www-form-urlencoded'].each do |type|
      it "preserves string keys and array values in #{type} body custom filters" do
        enable_sensitive_context
        filter = proc do |key, value, original|
          value.replace('[FILTERED]') if key == 'secret' && original['mode'] == 'private' && value.is_a?(String)
        end
        use_filters(filter)
        body = if type == 'application/json'
                 '{"mode":"private","nested":[{"secret":"PRIVATE_BODY"}]}'
               else
                 'mode=private&nested[][secret]=PRIVATE_BODY'
               end
        env = request_env(body, type)
        properties = capture_request(env)
        expect(properties['$request_body']).to eq('mode' => 'private', 'nested' => [{ 'secret' => '[FILTERED]' }])
        expect(properties['$request_params']['nested']).to eq([{ 'secret' => '[FILTERED]' }])
        expect(env['rack.input'].pos).to eq(0)
      end
    end

    it 'never partially truncates a value before an end-anchored Rails filter' do
      secret = "PRIVATE_LENGTH#{'x' * 10_000}MASK"
      filter = proc { |_key, value| value.replace('[FILTERED]') if value.is_a?(String) && value.end_with?('MASK') }
      use_filters(filter)
      ActiveSupport::ExecutionContext.set(secret: secret) do
        properties = capture_request(request_env)
        expect(JSON.generate(properties.fetch('$execution_context', {}))).not_to include('PRIVATE_LENGTH')
      end
    end

    it 'never partially truncates a key before an end-anchored Rails filter' do
      key = "#{'x' * 10_000}MASK"
      filter = proc { |name, value| value.replace('[FILTERED]') if name.to_s.end_with?('MASK') }
      use_filters(filter)
      ActiveSupport::ExecutionContext.set(data: { key => 'PRIVATE_KEY' }) do
        properties = capture_request(request_env)
        expect(JSON.generate(properties.fetch('$execution_context', {}))).not_to include('PRIVATE_KEY')
      end
    end

    it 'rejects broad context rather than running root-sensitive filters on a partial snapshot' do
      filter = proc do |key, value, original|
        value.replace('[FILTERED]') if key == :secret && original[:mode] == :private
      end
      use_filters(filter)
      context = { secret: 'PRIVATE_BROAD' }.merge((1..110).to_h { |index| ["filler#{index}", index] })
      context[:mode] = :private
      ActiveSupport::ExecutionContext.set(**context) do
        properties = capture_request(request_env)
        expect(JSON.generate(properties.fetch('$execution_context', {}))).not_to include('PRIVATE_BROAD')
      end
    end

    it 'rejects cycles without exposing sibling values through a partial filter snapshot' do
      filter = proc do |key, value, original|
        value.replace('[FILTERED]') if key == :secret && original[:cycle].equal?(original)
      end
      use_filters(filter)
      context = { secret: 'PRIVATE_CYCLE' }
      context[:cycle] = context
      env = request_env
      env['action_dispatch.request.parameters'] = context
      properties = capture_request(env)
      expect(JSON.generate(properties.fetch('$request_params', {}))).not_to include('PRIVATE_CYCLE')
      expect(context[:secret]).to eq('PRIVATE_CYCLE')
    end

    it 'copies mutable hash defaults before invoking original-root privacy filters' do
      source = Hash.new(+'application default')
      source[:secret] = +'PRIVATE_DEFAULT'
      use_filters(proc do |key, value, original|
        if key == :secret
          original.default.replace('changed by filter')
          value.replace('[FILTERED]')
        end
      end)
      env = request_env
      env['action_dispatch.request.parameters'] = source
      expect(capture_request(env)['$request_params']).to eq('secret' => '[FILTERED]')
      expect(source.default).to eq('application default')
      expect(source[:secret]).to eq('PRIVATE_DEFAULT')
    end

    it 'rejects callable hash defaults without executing application callbacks' do
      source = Hash.new { raise 'must not execute' }
      source[:secret] = +'PRIVATE_DEFAULT_PROC'
      filter = proc { |_key, _value, original| original[:missing] }
      use_filters(filter)
      expect(filter).not_to receive(:call)
      env = request_env
      env['action_dispatch.request.parameters'] = source
      expect(capture_request(env)['$request_params']).to eq({})
      expect(source[:secret]).to eq('PRIVATE_DEFAULT_PROC')
    end

    it 'preserves unchanged original root data for a third-argument filter with shared references' do
      shared = +'private mode'
      filter = proc do |key, value, original|
        if key == :secret && original[:first].equal?(original[:second])
          value.replace('[FILTERED]')
          original[:first].replace('scrubbed mode')
        end
      end
      use_filters(filter)
      ActiveSupport::ExecutionContext.set(secret: 'PRIVATE_SHARED', first: shared, second: shared) do
        properties = capture_request(request_env)
        expect(properties['$execution_context']['secret']).to eq('[FILTERED]')
      end
      expect(shared).to eq('private mode')
    end

    it 'preserves original string encoding and frozen state for root-sensitive Rails filters' do
      secret = 'PRIVATE_ENCODING'.dup.force_encoding(Encoding::ASCII_8BIT).freeze
      filter = proc do |key, value, original|
        source = original[:secret]
        value.replace('[FILTERED]') if key == :secret && source.frozen? && source.encoding == Encoding::ASCII_8BIT
      end
      use_filters(filter)
      ActiveSupport::ExecutionContext.set(secret: secret) do
        properties = capture_request(request_env)
        expect(properties['$execution_context']['secret']).to eq('[FILTERED]')
      end
      expect(secret).to eq('PRIVATE_ENCODING')
    end

    it 'rejects total byte and traversal overflows before invoking custom filters' do
      filter = proc { |_key, value| value.replace('[FILTERED]') if value.is_a?(String) }
      expect(filter).not_to receive(:call)
      use_filters(filter)
      byte_overflow = (1..4).to_h { |index| ["key#{index}", 'x' * 9_000] }
      node_overflow = (1..100).to_h { |index| ["key#{index}", Array.new(10, 1)] }
      deep = 20.times.reduce('PRIVATE_DEEP') { |value, _| { nested: value } }
      collector = PostHog::Rails::CaptureExceptions.new(->(_env) { raise error })
      [byte_overflow, node_overflow, deep].each do |metadata|
        expect(collector.send(:filtered_metadata, metadata)).to eq({})
      end
    end

    it 'passes original case-sensitive cookie String names to custom Rails filters' do
      enable_sensitive_context
      PostHog::Rails.config.exception_request_cookies = ['SessionKey']
      filter = proc { |key, value| value.replace('[FILTERED]') if key == 'SessionKey' && value == 'PRIVATE_COOKIE' }
      use_filters(filter)
      env = request_env
      env['HTTP_COOKIE'] = 'SessionKey=PRIVATE_COOKIE; sessionkey=not-allowlisted'
      properties = capture_request(env)
      expect(properties['$request_cookies']).to eq('SessionKey' => '[FILTERED]')
      expect(env['HTTP_COOKIE']).to include('SessionKey=PRIVATE_COOKIE')
    end
  end
end
