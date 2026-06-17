# frozen_string_literal: true

require 'spec_helper'

# Minimal requires for testing the Railtie in isolation
require 'logger'
require 'posthog'
require 'rails'
require 'rails/railtie'
require 'action_dispatch/middleware/stack'

# The posthog-rails lib has its own gemspec and isn't in the default load path,
# so we add it manually for testing.
$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)

# Load just enough of posthog-rails to define the Railtie.
# Middleware classes (CaptureExceptions, etc.) are only referenced inside
# initializer blocks, not at file-load time, so we don't need them here.
require 'posthog/rails/configuration'
require 'posthog/rails/railtie'

# The PostHog Logs wiring tests below exercise the full Rails integration
# (config singleton + Logs::Setup), so load it in full.
require 'posthog/rails'

RSpec.describe PostHog::Rails::Railtie do
  describe 'posthog.set_configs initializer' do
    before do
      initializer = PostHog::Rails::Railtie.initializers.find { |i| i.name == 'posthog.set_configs' }
      PostHog::Rails::Railtie.instance.instance_exec(double('app'), &initializer.block)
      PostHog::Logging.logger = Logger.new(File::NULL)
      PostHog.client = nil
    end

    after do
      PostHog.client = nil
    end

    it 'no-ops delegated calls before explicit init without logging a missing api_key error' do
      logger = instance_spy(Logger)
      PostHog::Logging.logger = logger

      expect { PostHog.capture(event: 'event', distinct_id: 'user') }.not_to raise_error
      expect(PostHog.capture(event: 'event', distinct_id: 'user')).to eq(false)
      expect(PostHog.identify(distinct_id: 'user')).to eq(false)
      expect(PostHog.alias(alias: 'anon', distinct_id: 'user')).to eq(false)
      expect(PostHog.group_identify(group_type: 'organization', group_key: 'id:5')).to eq(false)
      expect(PostHog.get_feature_flag('flag', 'user')).to be_nil
      expect(PostHog.get_all_flags('user')).to eq({})
      expect(PostHog.evaluate_flags('user').keys).to eq([])
      expect(logger).not_to have_received(:error)
    end

    it 'shuts down the previous client when init is called again' do
      previous_client = instance_spy(PostHog::Client)
      PostHog.client = previous_client

      new_client = PostHog.init(api_key: 'testsecret', test_mode: true)

      expect(new_client).to be_a(PostHog::Client)
      expect(PostHog.client).to eq(new_client)
      expect(previous_client).to have_received(:shutdown).once
    end
  end

  describe 'posthog.insert_middlewares initializer' do
    it 'has insert_middleware_after accessible from initializer context' do
      # Rails initializer blocks are executed via instance_exec on the Railtie
      # instance (see railties/lib/rails/initializable.rb). This means `self`
      # inside the block is the Railtie INSTANCE, not the class.
      #
      # Any method called without an explicit receiver in the block must be
      # defined as an instance method (or delegated to one).
      railtie = PostHog::Rails::Railtie.instance
      expect(railtie).to respond_to(:insert_middleware_after)
      expect(railtie).to respond_to(:insert_middleware_before)
    end

    it 'successfully records middleware operations when the initializer runs' do
      # Stub the middleware constants referenced in the initializer block
      stub_const('ActionDispatch::DebugExceptions', Class.new)
      stub_const('ActionDispatch::ShowExceptions', Class.new)
      stub_const('PostHog::Rails::RequestContext', Class.new)
      stub_const('PostHog::Rails::RescuedExceptionInterceptor', Class.new)
      stub_const('PostHog::Rails::CaptureExceptions', Class.new)

      # Find the initializer by name
      initializer = PostHog::Rails::Railtie.initializers.find { |i| i.name == 'posthog.insert_middlewares' }
      expect(initializer).not_to be_nil

      middleware_proxy = Rails::Configuration::MiddlewareStackProxy.new
      app = double('app', config: double('config', middleware: middleware_proxy))

      # Reproduce the exact execution context: the block is run via instance_exec
      # on the Railtie instance, with the app passed as the block argument.
      # This is how Rails runs initializer blocks internally.
      railtie = PostHog::Rails::Railtie.instance
      expect do
        railtie.instance_exec(app, &initializer.block)
      end.not_to raise_error
    end

    it 'inserts middleware before and after the target when it is present' do
      stub_const('TargetMiddleware', Class.new)
      stub_const('BeforeMiddleware', Class.new)
      stub_const('AfterMiddleware', Class.new)

      middleware_proxy = Rails::Configuration::MiddlewareStackProxy.new
      app = double('app', config: double('config', middleware: middleware_proxy))
      railtie = PostHog::Rails::Railtie.instance

      railtie.insert_middleware_before(app, TargetMiddleware, BeforeMiddleware)
      railtie.insert_middleware_after(app, TargetMiddleware, AfterMiddleware)

      stack = ActionDispatch::MiddlewareStack.new
      stack.use(TargetMiddleware)
      middleware_proxy.merge_into(stack)

      expected_middlewares = [
        BeforeMiddleware,
        TargetMiddleware,
        AfterMiddleware
      ]
      expect(stack.middlewares.map(&:klass)).to eq(expected_middlewares)
    end

    [
      {
        location: :after,
        existing_middlewares: [],
        expected_middlewares: %w[FallbackMiddleware]
      },
      {
        location: :before,
        existing_middlewares: %w[ExistingMiddleware],
        expected_middlewares: %w[FallbackMiddleware ExistingMiddleware]
      }
    ].each do |scenario|
      it "falls back when the deferred #{scenario[:location]} target is missing" do
        stub_const('MissingTargetMiddleware', Class.new)
        stub_const('ExistingMiddleware', Class.new)
        stub_const('FallbackMiddleware', Class.new)

        logger = instance_spy(Logger)
        PostHog::Logging.logger = logger
        middleware_proxy = Rails::Configuration::MiddlewareStackProxy.new
        app = double('app', config: double('config', middleware: middleware_proxy))

        PostHog::Rails::Railtie.instance.public_send(
          "insert_middleware_#{scenario[:location]}",
          app,
          MissingTargetMiddleware,
          FallbackMiddleware
        )

        stack = ActionDispatch::MiddlewareStack.new
        scenario[:existing_middlewares].each { |middleware| stack.use(Object.const_get(middleware)) }
        expected_middlewares = scenario[:expected_middlewares].map { |middleware| Object.const_get(middleware) }

        expect { middleware_proxy.merge_into(stack) }.not_to raise_error
        expect(stack.middlewares.map(&:klass)).to eq(expected_middlewares)
        expect(logger).to have_received(:warn).with(/Could not find MissingTargetMiddleware/)
      end
    end

    it 'records legacy middleware proxy operations with Rails 5/6 tuple format' do
      stub_const('MissingTargetMiddleware', Class.new)
      stub_const('FallbackMiddleware', Class.new)

      logger = instance_spy(Logger)
      PostHog::Logging.logger = logger
      middleware_proxy = Rails::Configuration::MiddlewareStackProxy.new
      middleware_proxy.instance_variable_set(:@operations, [[:use, [], nil]])
      app = double('app', config: double('config', middleware: middleware_proxy))

      PostHog::Rails::Railtie.instance.insert_middleware_after(
        app,
        MissingTargetMiddleware,
        FallbackMiddleware
      )

      legacy_operation, legacy_args, legacy_block = middleware_proxy.instance_variable_get(:@operations).last
      expect(legacy_operation).to eq(:posthog_insert_middleware_with_fallback)
      expect(legacy_args).to eq([:after, MissingTargetMiddleware, FallbackMiddleware])
      expect(legacy_block).to be_nil

      stack = ActionDispatch::MiddlewareStack.new
      stack.public_send(legacy_operation, *legacy_args, &legacy_block)

      expect(stack.middlewares.map(&:klass)).to eq([FallbackMiddleware])
      expect(logger).to have_received(:warn).with(/Could not find MissingTargetMiddleware/)
    end
  end

  describe 'PostHog Logs wiring' do
    around do |example|
      previous_config = PostHog::Rails.config
      PostHog::Rails.config = PostHog::Rails::Configuration.new
      example.run
    ensure
      PostHog::Rails.config = previous_config
    end

    before do
      initializer = PostHog::Rails::Railtie.initializers.find { |i| i.name == 'posthog.set_configs' }
      PostHog::Rails::Railtie.instance.instance_exec(double('app'), &initializer.block)
      PostHog::Logging.logger = Logger.new(File::NULL)
      PostHog.client = nil
    end

    after { PostHog.client = nil }

    describe 'PostHog.init' do
      it 'remembers the init options for the logs pipeline' do
        allow(PostHog::Rails::Logs::Setup).to receive(:remember_client_options)

        PostHog.init(api_key: 'phc_test', host: 'https://eu.i.posthog.com', test_mode: true)

        expect(PostHog::Rails::Logs::Setup).to have_received(:remember_client_options)
          .with(hash_including(api_key: 'phc_test', host: 'https://eu.i.posthog.com'))
      end
    end

    describe '.install_posthog_logs' do
      it 'skips with a warning when PostHog is not initialized' do
        allow(PostHog::Rails::Logs::Setup).to receive(:install)
        logger = instance_spy(Logger)
        PostHog::Logging.logger = logger

        PostHog::Rails::Railtie.install_posthog_logs

        expect(PostHog::Rails::Logs::Setup).not_to have_received(:install)
        expect(logger).to have_received(:warn).with(/PostHog Logs is enabled but PostHog\.init has not been called/)
      end

      it 'broadcasts Rails.logger when an appender is built' do
        PostHog.client = PostHog::Client.new(api_key: API_KEY, test_mode: true)
        appender = instance_double(PostHog::Rails::Logs::Appender)
        allow(PostHog::Rails::Logs::Setup).to receive(:install).and_return(appender)
        allow(PostHog::Rails::Railtie).to receive(:broadcast_rails_logger)

        PostHog::Rails::Railtie.install_posthog_logs

        expect(PostHog::Rails::Railtie).to have_received(:broadcast_rails_logger).with(appender)
      end

      it 'does not broadcast when logs_forward_rails_logger is disabled' do
        PostHog.client = PostHog::Client.new(api_key: API_KEY, test_mode: true)
        PostHog::Rails.config.logs_forward_rails_logger = false
        allow(PostHog::Rails::Logs::Setup).to receive(:install)
          .and_return(instance_double(PostHog::Rails::Logs::Appender))
        allow(PostHog::Rails::Railtie).to receive(:broadcast_rails_logger)

        PostHog::Rails::Railtie.install_posthog_logs

        expect(PostHog::Rails::Railtie).not_to have_received(:broadcast_rails_logger)
      end

      it 'does not broadcast when setup returns nil' do
        PostHog.client = PostHog::Client.new(api_key: API_KEY, test_mode: true)
        allow(PostHog::Rails::Logs::Setup).to receive(:install).and_return(nil)
        allow(PostHog::Rails::Railtie).to receive(:broadcast_rails_logger)

        PostHog::Rails::Railtie.install_posthog_logs

        expect(PostHog::Rails::Railtie).not_to have_received(:broadcast_rails_logger)
      end

      it 'skips quietly when the client is disabled (missing/blank api_key)' do
        PostHog.client = PostHog::Client.new(api_key: '', silence_disabled_client_error: true)
        logger = instance_spy(Logger)
        PostHog::Logging.logger = logger
        allow(PostHog::Rails::Logs::Setup).to receive(:install)

        PostHog::Rails::Railtie.install_posthog_logs

        expect(PostHog::Rails::Logs::Setup).not_to have_received(:install)
        expect(logger).not_to have_received(:warn)
      end
    end

    describe '.broadcast_rails_logger' do
      let(:appender) { instance_double(PostHog::Rails::Logs::Appender) }

      it 'uses broadcast_to on Rails 7.1+ broadcast loggers' do
        logger = double('logger')
        allow(logger).to receive(:respond_to?).with(:broadcast_to).and_return(true)
        allow(logger).to receive(:broadcast_to)
        allow(Rails).to receive(:logger).and_return(logger)

        PostHog::Rails::Railtie.broadcast_rails_logger(appender)

        expect(logger).to have_received(:broadcast_to).with(appender)
      end

      it 'falls back to ActiveSupport::Logger.broadcast on older Rails' do
        logger = double('logger')
        allow(logger).to receive(:respond_to?).with(:broadcast_to).and_return(false)
        allow(logger).to receive(:extend)
        allow(Rails).to receive(:logger).and_return(logger)

        broadcast_module = Module.new
        allow(ActiveSupport::Logger).to receive(:respond_to?).with(:broadcast).and_return(true)
        allow(ActiveSupport::Logger).to receive(:broadcast).with(appender).and_return(broadcast_module)

        PostHog::Rails::Railtie.broadcast_rails_logger(appender)

        expect(logger).to have_received(:extend).with(broadcast_module)
      end
    end
  end
end
