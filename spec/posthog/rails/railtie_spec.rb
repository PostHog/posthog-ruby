# frozen_string_literal: true

# Minimal requires for testing the Railtie in isolation
require 'posthog'
require 'rails/railtie'

# The posthog-rails lib has its own gemspec and isn't in the default load path,
# so we add it manually for testing.
$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)

# Stub minimal Rails interface needed by posthog-rails submodules
module Rails
  def self.version
    '7.2.0'
  end

  def self.logger
    @logger ||= Logger.new(File::NULL)
  end
end

# Load the full posthog-rails module, which also extends PostHog with
# init, capture, and other singleton methods at load time.
require 'posthog/rails'

RSpec.describe PostHog::Rails::Railtie do
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
    end

    it 'successfully calls insert_middleware_after when the initializer runs' do
      # Stub the middleware constants referenced in the initializer block
      stub_const('ActionDispatch::DebugExceptions', Class.new)
      stub_const('ActionDispatch::ShowExceptions', Class.new)
      stub_const('PostHog::Rails::RescuedExceptionInterceptor', Class.new)
      stub_const('PostHog::Rails::CaptureExceptions', Class.new)

      # Find the initializer by name
      initializer = PostHog::Rails::Railtie.initializers.find { |i| i.name == 'posthog.insert_middlewares' }
      expect(initializer).not_to be_nil

      # During initialization, app.config.middleware is a MiddlewareStackProxy
      # which only supports recording operations — NOT query methods like include?.
      # The mock must reflect this accurately.
      middleware_proxy = double('MiddlewareStackProxy', insert_after: true)
      app = double('app', config: double('config', middleware: middleware_proxy))

      # Reproduce the exact execution context: the block is run via instance_exec
      # on the Railtie instance, with the app passed as the block argument.
      # This is how Rails runs initializer blocks internally.
      railtie = PostHog::Rails::Railtie.instance
      expect do
        railtie.instance_exec(app, &initializer.block)
      end.not_to raise_error
    end
  end

  describe 'PostHog.init availability at gem load time' do
    before do
      PostHog.instance_variable_set(:@client, nil)
      PostHog::Client.reset_instance_tracking!
    end

    after do
      PostHog.instance_variable_set(:@client, nil)
      PostHog::Client.reset_instance_tracking!
    end

    it 'PostHog.init can be called without any Rails initializer having run' do
      expect do
        PostHog.init(api_key: 'test-key', test_mode: true)
      end.not_to raise_error

      expect(PostHog.initialized?).to be true
      expect(PostHog.client).to be_a(PostHog::Client)
    end

    it 'PostHog.init with block configuration works without Rails initializers' do
      expect do
        PostHog.init do |config|
          config.api_key = 'test-key'
          config.test_mode = true
        end
      end.not_to raise_error

      expect(PostHog.initialized?).to be true
    end

    it 'raises a clear error when delegated methods are called before init' do
      expect(PostHog.initialized?).to be false

      expect do
        PostHog.capture(distinct_id: 'test', event: 'test')
      end.to raise_error(RuntimeError, /PostHog is not initialized/)
    end
  end
end
