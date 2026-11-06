# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rails'
require 'action_controller'
require 'action_view'
require 'rack/mock'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'

RSpec.describe 'Rails streaming exception capture' do
  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }
  let(:error) do
    raise 'stream failed'
  rescue RuntimeError => e
    e
  end
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }

  around do |example|
    previous_client = PostHog.client
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails.config.auto_capture_exceptions = true
    example.run
  ensure
    PostHog.client = previous_client
    PostHog::Rails.config = previous_config
  end

  before do
    PostHog.client = client
    allow(ActionController::Base).to receive(:logger).and_return(logger)
    allow(ActionView::Base).to receive(:logger).and_return(logger)
    initializer = PostHog::Rails::Railtie.initializers.find { |i| i.name == 'posthog.streaming_errors' }
    PostHog::Rails::Railtie.instance.instance_exec(nil, &initializer.block)
  end

  def live_response(error, user_id: nil, clear_context: false, &after_response)
    release = Queue.new
    controller = Class.new(ActionController::Base) do
      include ActionController::Live

      define_method(:index) do
        response.headers['Content-Type'] = 'text/event-stream'
        response.stream.write('started')
        release.pop
        PostHog.const_get(:Internal)::Context.current = nil if clear_context
        raise error
      end
      define_method(:current_user) { Struct.new(:id).new(user_id) if user_id }
    end
    stub_const('StreamingErrorsController', controller)
    env = Rack::MockRequest.env_for('/stream?password=secret&visible=yes',
                                    'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user',
                                    'HTTP_X_POSTHOG_SESSION_ID' => 'header-session')
    response = PostHog::Rails::RequestContext.new(
      PostHog::Rails::CaptureExceptions.new(controller.action(:index))
    ).call(env)
    after_response&.call
    release << true
    chunks = +''
    response[2].each { |chunk| chunks << chunk }
    expect(chunks).to include('started')
    expect(response[0]).to eq(200)
    expect(PostHog.const_get(:Internal)::Context.current).to be_nil
    response
  ensure
    response&.[](2)&.close
  end

  def template_body(error)
    ActionView::StreamingTemplateRenderer::Body.new do |buffer|
      buffer.call('started')
      raise error
    end
  end

  it 'captures Live failures after middleware returns with filtered request context and authenticated identity' do
    allow(Rails).to receive(:application).and_return(
      double(config: double(root: nil, filter_parameters: [:password]))
    )
    live_response(error, user_id: 'authenticated-user') do
      expect(PostHog.const_get(:Internal)::Context.current).to be_nil
      expect(client.queued_messages).to eq(0)
    end

    expect(client.queued_messages).to eq(1)
    event = client.dequeue_last_message
    expect(event[:distinct_id]).to eq('authenticated-user')
    expect(event[:properties]).to include(
      '$request_path' => '/stream', '$session_id' => 'header-session',
      '$exception_source' => 'rails.live', '$exception_level' => 'error',
      '$request_params' => { 'password' => '[FILTERED]', 'visible' => 'yes' }
    )
    expect(event[:properties]['$exception_list'].first['mechanism']).to include('type' => 'middleware',
                                                                                'handled' => false)
    expect(log_output.string).to include('stream failed')
  end

  it 'uses request headers as fallback identity for Live failures without leaking into later events' do
    live_response(error, clear_context: true)
    expect(client.queued_messages).to eq(1)
    expect(client.dequeue_last_message[:distinct_id]).to eq('header-user')
    client.capture(event: 'later')
    event = client.dequeue_last_message
    expect(event[:distinct_id]).not_to eq('header-user')
    expect(event[:properties]).not_to have_key('$session_id')
    expect(event[:properties]).not_to have_key('$request_path')
  end

  it 'uses the Live request rather than an unrelated ambient scope and restores that scope' do
    controller = Class.new(ActionController::Base) { include ActionController::Live }.new
    env = Rack::MockRequest.env_for('/stream', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'request-user',
                                               'HTTP_X_POSTHOG_SESSION_ID' => 'request-session')
    controller.set_request!(ActionDispatch::Request.new(env))
    context_class = PostHog.const_get(:Internal)::Context
    context_class.with_context(distinct_id: 'unrelated-user', session_id: 'unrelated-session',
                               properties: { '$request_path' => '/unrelated' }) do
      previous = context_class.current
      controller.send(:log_error, error)
      expect(context_class.current).to equal(previous)
      expect(client.queued_messages).to eq(1)
      event = client.dequeue_last_message
      expect(event[:distinct_id]).to eq('request-user')
      expect(event[:properties]).to include('$session_id' => 'request-session', '$request_path' => '/stream')
    end
  end

  it 'does not annotate an unrelated active span while restoring Live request context' do
    begin
      require 'opentelemetry-sdk'
    rescue LoadError
      skip 'Install the gemfiles/otel.gemfile bundle to run span integration'
    end
    controller = Class.new(ActionController::Base) { include ActionController::Live }.new
    env = Rack::MockRequest.env_for('/stream', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'request-user',
                                               'HTTP_X_POSTHOG_SESSION_ID' => 'request-session')
    controller.set_request!(ActionDispatch::Request.new(env))
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    span = provider.tracer('streaming-isolation').start_span('unrelated-work')
    context_class = PostHog.const_get(:Internal)::Context
    OpenTelemetry::Trace.with_span(span) do
      context_class.with_context(distinct_id: 'unrelated-user', session_id: 'unrelated-session',
                                 owner: client, enrich_current_span: false) do
        previous = context_class.current
        controller.send(:log_error, error)
        expect(context_class.current).to equal(previous)
        expect(client.dequeue_last_message[:distinct_id]).to eq('request-user')
        expect(span.attributes).to eq({})
      end
    end
  ensure
    span&.finish
    provider&.shutdown
  end

  it 'captures the real template body reporter and preserves its completion and return value' do
    body = template_body(error)
    chunks = []
    result = PostHog::Rails::RequestContext.new(lambda do |_env|
      expect(body.each { |chunk| chunks << chunk }).to equal(body)
      [200, {}, []]
    end).call(Rack::MockRequest.env_for('/template', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'template-user'))

    expect(result[0]).to eq(200)
    expect(chunks).to eq(['started', ActionView::Base.streaming_completion_on_exception])
    expect(log_output.string).to include('stream failed')
    expect(client.queued_messages).to eq(1)
    event = client.dequeue_last_message
    expect(event[:distinct_id]).to eq('template-user')
    expect(event[:properties]).to include('$exception_source' => 'rails.streaming_template',
                                          '$exception_level' => 'error')
    expect(event[:properties]['$exception_list'].first['mechanism']).to include('type' => 'middleware',
                                                                                'handled' => false)
    expect(body).not_to respond_to(:log_error)
    expect(ActionController::Live.private_instance_methods).to include(:log_error)
  end

  it 'does not pin the context from template body creation' do
    body = nil
    PostHog::Rails::RequestContext.new(lambda do |_env|
      body = template_body(error)
      [200, {}, []]
    end).call(Rack::MockRequest.env_for('/old', 'HTTP_X_POSTHOG_DISTINCT_ID' => 'old-user'))
    body.each { |chunk| expect(chunk).to be_a(String) }
    expect(client.queued_messages).to eq(1)
    event = client.dequeue_last_message
    expect(event[:distinct_id]).not_to eq('old-user')
    expect(event[:properties]).not_to have_key('$request_path')
  end

  def run_reporter(reporter, error)
    reporter == :live ? live_response(error) : template_body(error).each { |chunk| expect(chunk).to be_a(String) }
  end

  %i[live template].each do |reporter|
    it "keeps #{reporter} logging and completion when capture fails" do
      allow(PostHog).to receive(:capture_exception).and_raise('capture failed')
      expect { run_reporter(reporter, error) }.not_to raise_error
      expect(log_output.string).to include('stream failed')
    end

    it "deduplicates #{reporter} failures already captured by the core client" do
      client.capture_exception(error)
      run_reporter(reporter, error)
      expect(client.queued_messages).to eq(1)
    end

    it "respects auto_capture_exceptions for #{reporter}" do
      PostHog::Rails.config.auto_capture_exceptions = false
      run_reporter(reporter, error)
      expect(client.queued_messages).to eq(0)
      expect(log_output.string).to include('stream failed')
    end

    it "respects excluded exceptions for #{reporter}" do
      PostHog::Rails.config.excluded_exceptions = ['RuntimeError']
      run_reporter(reporter, error)
      expect(client.queued_messages).to eq(0)
    end

    it "no-ops before initialization for #{reporter}" do
      PostHog.client = nil
      expect { run_reporter(reporter, error) }.not_to raise_error
      expect(log_output.string).to include('stream failed')
    end

    it "no-ops with a disabled client for #{reporter}" do
      allow(client).to receive(:enabled?).and_return(false)
      expect(PostHog).not_to receive(:capture_exception)
      run_reporter(reporter, error)
      expect(log_output.string).to include('stream failed')
    end
  end

  it 'preserves errors raised by Rails logging itself' do
    logging_error = RuntimeError.new('logging failed')
    allow(logger).to receive(:fatal).and_raise(logging_error)
    expect { template_body(error).each { |chunk| expect(chunk).to be_a(String) } }.to(raise_error do |raised|
      expect(raised).to equal(logging_error)
    end)
  end

  it 'preserves the return value of both original private logging methods' do
    allow(logger).to receive(:fatal).and_return(:logged)
    controller = Class.new(ActionController::Base) { include ActionController::Live }.new
    expect(controller.send(:log_error, error)).to eq(:logged)
    expect(template_body(error).send(:log_error, error)).to eq(:logged)
  end

  %w[before after].each do |load_order|
    it "installs lazily and once when streaming components load #{load_order} the initializer" do
      script = <<~RUBY
        require 'posthog'
        require 'rails'
        require 'posthog/rails'
        initializer = PostHog::Rails::Railtie.initializers.find { |i| i.name == 'posthog.streaming_errors' }
        install = -> { PostHog::Rails::Railtie.instance.instance_exec(nil, &initializer.block) }
        if #{load_order == 'after'}
          install.call
          abort 'eager controller load' if $LOADED_FEATURES.any? { |path| path.end_with?('/metal/live.rb') }
          abort 'eager view load' if $LOADED_FEATURES.any? { |path| path.end_with?('/streaming_template_renderer.rb') }
        end
        require 'action_controller'
        require 'action_view'
        ActionController::Base
        ActionView::Base
        install.call
        install.call
        # Exercise the newer Live-specific hook as well as the older controller hook.
        ActiveSupport.run_load_hooks(:action_controller_live, ActionController::Live)
        integration = PostHog::Rails.const_get(:StreamingExceptions)
        abort 'duplicate Live wrapper' unless ActionController::Live.ancestors.count(integration::LiveReporter) == 1
        body = ActionView::StreamingTemplateRenderer::Body
        abort 'duplicate template wrapper' unless body.ancestors.count(integration::TemplateReporter) == 1
        abort 'public Live logger' unless ActionController::Live.private_instance_methods.include?(:log_error)
        abort 'public template logger' unless body.private_instance_methods.include?(:log_error)
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib', '-e', script)
      expect(status).to be_success, "#{stdout}\n#{stderr}"
    end
  end

  it 'does not resolve Live on controller load on Rails with a dedicated Live hook' do
    script = <<~RUBY
      require 'posthog'
      require 'rails'
      require 'posthog/rails'
      def Rails.version
        '8.1.4'
      end
      initializer = PostHog::Rails::Railtie.initializers.find { |i| i.name == 'posthog.streaming_errors' }
      2.times { PostHog::Rails::Railtie.instance.instance_exec(nil, &initializer.block) }
      require 'action_controller'
      ActionController::Base
      abort 'eager Live load' if $LOADED_FEATURES.any? { |path| path.end_with?('/metal/live.rb') }
      live = ActionController::Live
      ActiveSupport.run_load_hooks(:action_controller_live, live)
      integration = PostHog::Rails.const_get(:StreamingExceptions)
      abort 'missing or duplicate wrapper' unless live.ancestors.count(integration::LiveReporter) == 1
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib', '-e', script)
    expect(status).to be_success, "#{stdout}\n#{stderr}"
  end

  it 'does not register load callbacks again when installation repeats' do
    allow(ActiveSupport).to receive(:on_load).and_call_original
    initializer = PostHog::Rails::Railtie.initializers.find { |i| i.name == 'posthog.streaming_errors' }
    2.times { PostHog::Rails::Railtie.instance.instance_exec(nil, &initializer.block) }
    expect(ActiveSupport).not_to have_received(:on_load)
  end

  it 'preserves public Live reporter visibility used by older Rails' do
    live = Module.new do
      def log_error(_error)
        :logged
      end
    end
    ActiveSupport.run_load_hooks(:action_controller_live, live)
    expect(live.public_instance_methods).to include(:log_error)
  end
end
