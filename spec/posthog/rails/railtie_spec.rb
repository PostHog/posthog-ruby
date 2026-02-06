# frozen_string_literal: true

# Minimal requires for testing the Railtie in isolation
require 'posthog'
require 'rails/railtie'

# The posthog-rails lib has its own gemspec and isn't in the default load path,
# so we add it manually for testing.
$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)

# Load just enough of posthog-rails to define the Railtie.
# Middleware classes (CaptureExceptions, etc.) are only referenced inside
# initializer blocks, not at file-load time, so we don't need them here.
require 'posthog/rails/configuration'
require 'posthog/rails/railtie'

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
      expect {
        railtie.instance_exec(app, &initializer.block)
      }.not_to raise_error
    end
  end
end
