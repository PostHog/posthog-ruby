# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'action_dispatch'
require 'rack/mock'
require 'action_cable'
require 'open3'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'

RSpec.describe 'Action Cable exception capture' do
  let(:context_class) { PostHog.const_get(:Internal).const_get(:Context) }
  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }
  let(:env) do
    Rack::MockRequest.env_for('/cable?token=private', {
                                'HTTP_X_POSTHOG_DISTINCT_ID' => " browser-user\n",
                                'HTTP_X_POSTHOG_SESSION_ID' => 'browser-session',
                                'HTTP_COOKIE' => 'authentication=private',
                                'HTTP_AUTHORIZATION' => 'Bearer private',
                                'HTTP_USER_AGENT' => 'Cable test'
                              })
  end
  let(:server) do
    ActionCable::Server::Base.new.tap do |value|
      value.config.logger = Logger.new(File::NULL)
    end
  end
  let(:connection_class) do
    stub_const('PostHogCableConnection', Class.new(ActionCable::Connection::Base) do
      attr_accessor :failure, :observer

      def connect
        observer&.call
        raise failure if failure
      end

      def disconnect
        observer&.call
        raise failure if failure

        :disconnected
      end
    end)
    PostHogCableConnection
  end
  let(:connection) { connection_class.new(server, env) }
  let(:channel_class) do
    stub_const('PostHogCableChannel', Class.new(ActionCable::Channel::Base) do
      class_attribute :failure, :observer
      before_subscribe { self.class.observer&.call(:before_subscribe) }
      after_subscribe { self.class.observer&.call(:after_subscribe) }
      after_unsubscribe { self.class.observer&.call(:after_unsubscribe) }

      def subscribed
        raise self.class.failure if self.class.failure
      end

      def unsubscribed
        raise self.class.failure if self.class.failure

        :unsubscribed
      end

      def speak(data)
        self.class.observer&.call(data)
        raise self.class.failure if self.class.failure

        :spoken
      end
    end)
    PostHogCableChannel
  end
  let(:channel) { channel_class.new(connection, 'private identifier', { 'room' => 'lobby', 'token' => 'private' }) }
  let(:error) { RuntimeError.new('cable failed') }

  around do |example|
    PostHog::Logging.logger = Logger.new(File::NULL)
    previous_client = PostHog.client
    previous_config = PostHog::Rails.config
    PostHog.client = client
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails.config.auto_capture_exceptions = true
    example.run
  ensure
    PostHog.client = previous_client
    PostHog::Rails.config = previous_config
    client.shutdown
  end

  before do
    # Run the real integration initializer, then let Rails execute actual load hooks.
    initializer = PostHog::Rails::Railtie.initializers.find { |item| item.name == 'posthog.action_cable' }
    initializer&.run(Rails.application)
    allow(Rails).to receive(:application).and_return(
      double('application', env_config: {}, config: double(root: nil, filter_parameters: %i[token password]))
    )
  end

  def expect_original_error(&block)
    expect(&block).to(raise_error { |raised| expect(raised).to equal(error) })
  end

  %i[handle_open handle_close].each do |operation|
    it "captures connection #{operation} failures with request context and restores the caller" do
      connection.failure = error
      allow(connection).to receive(:websocket).and_return(double(protocol: 'actioncable-v1-json', possible?: true))
      allow(connection).to receive(:unsubscribe_from_internal_channel)
      context_class.with_context(distinct_id: 'unrelated', session_id: 'unrelated-session') do
        outer = context_class.current
        expect_original_error { connection.send(operation) }
        expect(context_class.current).to equal(outer)
      end
      expect(client.queued_messages).to eq(1)
      event = client.dequeue_last_message
      expect(event[:distinct_id]).to eq('browser-user')
      expect(event[:properties]).to include(
        '$session_id' => 'browser-session', '$request_path' => '/cable',
        '$current_url' => 'http://example.org/cable', '$user_agent' => 'Cable test',
        '$exception_source' => 'rails.action_cable', '$connection_class' => 'PostHogCableConnection'
      )
      expect(event[:properties]['$exception_list'].first['mechanism']).to include('type' => 'middleware',
                                                                                  'handled' => false)
      expect(event[:properties].except('$exception_list').to_json).not_to include('private', 'unrelated')
    end
  end

  {
    subscribe_to_channel: 'subscribe', unsubscribe_from_channel: 'unsubscribe', perform_action: 'action'
  }.each do |method_name, operation|
    it "captures #{operation} errors with filtered channel and action details" do
      channel_class.failure = error
      expect_original_error do
        if method_name == :perform_action
          channel.perform_action('action' => 'speak', 'password' => 'private')
        else
          channel.public_send(method_name)
        end
      end
      expect(client.queued_messages).to eq(1)
      properties = client.dequeue_last_message[:properties]
      expect(properties).to include(
        '$exception_source' => 'rails.action_cable', '$action_cable_operation' => operation,
        '$channel_class' => 'PostHogCableChannel', '$connection_class' => 'PostHogCableConnection',
        '$channel_params' => { 'room' => 'lobby', 'token' => '[FILTERED]' }
      )
      if method_name == :perform_action
        expect(properties).to include('$action' => 'speak',
                                      '$action_data' => { 'action' => 'speak',
                                                          'password' => '[FILTERED]' })
      end
      expect(properties.except('$exception_list').to_json).not_to include('private')
      expect(context_class.current).to be_nil
    end
  end

  it 'captures errors from real before/after channel callbacks' do
    %i[before_subscribe after_subscribe after_unsubscribe].each do |callback|
      channel_class.observer = ->(stage) { raise "#{callback} failed" if stage == callback }
      method_name = callback == :after_unsubscribe ? :unsubscribe_from_channel : :subscribe_to_channel
      expect { channel.public_send(method_name) }.to raise_error("#{callback} failed")
    end
    expect(client.queued_messages).to eq(3)
  end

  it 'preserves return values and context throughout successful callbacks and actions' do
    observations = []
    channel_class.observer = lambda do |_stage|
      observations << [context_class.current.distinct_id, context_class.current.session_id]
    end
    channel.subscribe_to_channel
    expect(channel.perform_action('action' => 'speak')).to eq(:spoken)
    expect(channel.unsubscribe_from_channel).to eq(:unsubscribed)
    expect(observations).to eq(Array.new(4) { %w[browser-user browser-session] })
    expect(client.queued_messages).to eq(0)
    expect(context_class.current).to be_nil
  end

  it 'preserves successful connection returns and restores context after open and close' do
    observations = []
    connection.observer = -> { observations << context_class.current.distinct_id }
    allow(connection).to receive_messages(websocket: double(protocol: 'actioncable-v1-json', possible?: true),
                                          subscribe_to_internal_channel: nil, unsubscribe_from_internal_channel: nil,
                                          send_welcome_message: nil, message_buffer: double(process!: nil))
    allow(server).to receive(:add_connection).with(connection).and_return(:opened)
    expect(connection.send(:handle_open)).to eq(:opened)
    expect(connection.send(:handle_close)).to eq(:disconnected)
    expect(observations).to eq(%w[browser-user browser-user])
    expect(context_class.current).to be_nil
    expect(client.queued_messages).to eq(0)
  end

  it 'does not capture when disabled by default or explicitly excluded' do
    channel_class.failure = error
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    expect_original_error { channel.perform_action('action' => 'speak') }
    PostHog::Rails.config.auto_capture_exceptions = true
    PostHog::Rails.config.excluded_exceptions = ['RuntimeError']
    expect_original_error { channel.perform_action('action' => 'speak') }
    expect(client.queued_messages).to eq(0)
  end

  it 'does not initialize a missing facade client or capture with a disabled client' do
    channel_class.failure = error
    PostHog.client = nil
    expect_original_error { channel.perform_action('action' => 'speak') }
    expect(PostHog.client).to be_nil
    PostHog.client = PostHog::Client.new(api_key: nil, silence_disabled_client_error: true)
    expect_original_error { channel.perform_action('action' => 'speak') }
    expect(PostHog.client.queued_messages).to eq(0)
  ensure
    PostHog.client&.shutdown
  end

  it 'respects tracing header opt-out and stronger authenticated request identity' do
    env['action_controller.instance'] = double(current_user: double(id: 'authenticated'))
    channel_class.failure = error
    expect_original_error { channel.perform_action('action' => 'speak') }
    expect(client.dequeue_last_message[:distinct_id]).to eq('authenticated')
    PostHog::Rails.config.capture_user_context = false
    PostHog::Rails.config.use_tracing_headers = false
    channel_class.failure = RuntimeError.new('again')
    expect { channel.perform_action('action' => 'speak') }.to raise_error('again')
    event = client.dequeue_last_message
    expect(event[:distinct_id]).not_to eq('browser-user')
    expect(event[:properties]).not_to have_key('$session_id')
  end

  it 'prefers the configured authenticated connection user without passing it to a controller resolver' do
    connection_class.class_eval { attr_accessor :signed_in_user }
    connection.signed_in_user = Struct.new(:account_id).new('connection-user')
    PostHog::Rails.config.current_user_method = :signed_in_user
    PostHog::Rails.config.user_id_method = :account_id
    PostHog::Rails.config.current_user_resolver = ->(_controller) { raise 'controller required' }
    channel_class.failure = error
    expect_original_error { channel.perform_action('action' => 'speak') }
    expect(client.dequeue_last_message[:distinct_id]).to eq('connection-user')

    PostHog::Rails.config.capture_user_context = false
    channel_class.failure = RuntimeError.new('next action')
    expect { channel.perform_action('action' => 'speak') }.to raise_error('next action')
    expect(client.dequeue_last_message[:distinct_id]).to eq('browser-user')
  end

  it 'falls back to headers when the connection current_user method raises' do
    connection_class.class_eval { def current_user = raise('user unavailable') }
    channel_class.failure = error
    expect_original_error { channel.perform_action('action' => 'speak') }
    expect(client.dequeue_last_message[:distinct_id]).to eq('browser-user')
  end

  it 'uses default current_user IDs and falls back when reading the user ID fails' do
    connection_class.class_eval { attr_accessor :current_user }
    connection.current_user = Struct.new(:id).new('signed-in')
    channel_class.failure = error
    expect_original_error { channel.perform_action('action' => 'speak') }
    expect(client.dequeue_last_message[:distinct_id]).to eq('signed-in')

    user = Object.new
    def user.id
      raise 'ID unavailable'
    end
    connection.current_user = user
    channel_class.failure = RuntimeError.new('next failure')
    expect { channel.perform_action('action' => 'speak') }.to raise_error('next failure')
    expect(client.queued_messages).to eq(1)
    expect(client.dequeue_last_message[:distinct_id]).to eq('browser-user')
  end

  it 'does not duplicate captures when a channel failure escapes connection close' do
    channel_class.failure = error
    allow(connection.subscriptions).to receive(:unsubscribe_from_all) { channel.unsubscribe_from_channel }
    expect_original_error { connection.send(:handle_close) }
    expect(client.queued_messages).to eq(1)
    expect(client.dequeue_last_message[:properties]['$channel_class']).to eq('PostHogCableChannel')
  end

  it 'keeps different socket actions isolated, including test connections without env' do
    first_connection = Struct.new(:env, :identifiers, :logger).new(env, [], Logger.new(File::NULL))
    missing_env_connection = Struct.new(:identifiers, :logger).new([], Logger.new(File::NULL))
    channel_class.observer = ->(_data) { PostHog.capture(event: 'socket action') }
    [first_connection, missing_env_connection].each do |socket|
      channel_class.new(socket, '').perform_action('action' => 'speak')
    end
    first = client.dequeue_last_message
    second = client.dequeue_last_message
    expect(first[:distinct_id]).to eq('browser-user')
    expect(second[:distinct_id]).not_to eq('browser-user')
    expect(second[:properties]).not_to have_key('$session_id')
    expect(context_class.current).to be_nil
  end

  it 'captures personless failures on test connections without env' do
    socket = Struct.new(:identifiers, :logger).new([], Logger.new(File::NULL))
    channel_class.failure = error
    expect_original_error { channel_class.new(socket, '').perform_action('action' => 'speak') }
    event = client.dequeue_last_message
    expect(event[:properties]['$process_person_profile']).to be(false)
    expect(event[:properties]).not_to have_key('$session_id')
  end

  it 'isolates concurrent sockets and restores the worker context after errors' do
    ready = Queue.new
    proceed = Queue.new
    results = Queue.new
    channel_class.observer = lambda do |_data|
      ready << true
      proceed.pop
      results << context_class.current.distinct_id
      raise 'socket action failed'
    end
    channels = %w[first second].map do |id|
      socket_env = env.merge('HTTP_X_POSTHOG_DISTINCT_ID' => id)
      socket = Struct.new(:env, :identifiers, :logger).new(socket_env, [], Logger.new(File::NULL))
      channel_class.new(socket, '')
    end
    threads = channels.map do |socket_channel|
      Thread.new do
        context_class.with_context(distinct_id: 'worker') do
          begin
            socket_channel.perform_action('action' => 'speak')
          rescue RuntimeError => e
            results << e.message
          end
          results << context_class.current.distinct_id
        end
      end
    end
    2.times { ready.pop }
    2.times { proceed << true }
    threads.each(&:value)
    expect(6.times.map { results.pop }).to contain_exactly(
      'first', 'second', 'socket action failed', 'socket action failed', 'worker', 'worker'
    )
    expect(2.times.map { client.dequeue_last_message[:distinct_id] }).to match_array(%w[first second])
    expect(context_class.current).to be_nil
  end

  it 'does not change an ambient span when establishing socket context' do
    span_context = PostHog.const_get(:Internal).const_get(:SpanContext)
    allow(span_context).to receive(:apply_current)
    channel.perform_action('action' => 'speak')
    expect(span_context).not_to have_received(:apply_current)
  end

  it 'uses the current facade owner rather than retaining the upgrade request client' do
    previous_owner = PostHog::Client.new(api_key: API_KEY, test_mode: true)
    channel_class.observer = ->(_data) { expect(context_class.current.owner).to equal(client) }
    context_class.with_context(distinct_id: 'old', owner: previous_owner) do
      channel.perform_action('action' => 'speak')
      expect(context_class.current.owner).to equal(previous_owner)
    end
  ensure
    previous_owner.shutdown
  end

  it 'keeps original exceptions when capture or parameter filtering fails' do
    channel_class.failure = error
    allow(PostHog).to receive(:capture_exception).and_raise('capture failed')
    expect_original_error { channel.perform_action('action' => 'speak') }
    allow(PostHog::Rails::ParameterFilter.backend).to receive(:new).and_raise('filter failed')
    expect_original_error { channel.perform_action('action' => 'speak') }
    expect(context_class.current).to be_nil
  end

  it 'uses the existing before_send hook, including drops' do
    replacement = PostHog::Client.new(api_key: API_KEY, test_mode: true, before_send: ->(_event) {})
    PostHog.client = replacement
    channel_class.failure = error
    expect_original_error { channel.perform_action('action' => 'speak') }
    expect(replacement.queued_messages).to eq(0)
  ensure
    replacement&.shutdown
  end

  it 'installs through a real Rails application boot with Action Cable already loaded' do
    script = <<~RUBY
      require 'rails'
      require 'action_controller/railtie'
      require 'action_cable/engine'
      require 'posthog-rails'
      require 'tmpdir'
      ActionCable::Connection::Base.name
      ActionCable::Channel::Base.name
      class CableIntegrationApp < Rails::Application
        config.eager_load = false
        config.logger = Logger.new(File::NULL)
        config.secret_key_base = 'test-key' * 16
      end
      Dir.mktmpdir('posthog-cable') do |root|
        app = CableIntegrationApp.instance
        app.config.root = root
        app.initialize!
        PostHog.init(api_key: 'test', test_mode: true)
        PostHog::Rails.config.auto_capture_exceptions = true
        class BootChannel < ActionCable::Channel::Base
          def speak
            raise 'boot action failed'
          end
        end
        connection = Struct.new(:identifiers, :logger).new([], Logger.new(File::NULL))
        begin
          BootChannel.new(connection, '').perform_action('action' => 'speak')
        rescue RuntimeError => e
          abort 'wrong exception' unless e.message == 'boot action failed'
        end
        abort 'missing capture' unless PostHog.client.queued_messages == 1
        event = PostHog.client.dequeue_last_message
        abort 'wrong source' unless event[:properties]['$exception_source'] == 'rails.action_cable'
        abort 'context leak' if PostHog.const_get(:Internal).const_get(:Context).current
      end
    RUBY
    output, status = Open3.capture2e('bundle', 'exec', 'ruby', '-Ilib:posthog-rails/lib', '-e', script)
    expect(status.success?).to be(true), output
  end

  it 'registers lazy load hooks without loading optional Action Cable components' do
    script = <<~RUBY
      require 'rails'
      require 'posthog/rails'
      initializer = PostHog::Rails::Railtie.initializers.find { |item| item.name == 'posthog.action_cable' }
      abort 'missing initializer' unless initializer
      initializer.run(nil)
      abort 'eager load' if defined?(ActionCable::Connection::Base)
      require 'action_cable'
      abort 'connection hook missing' unless ActionCable::Connection::Base.private_instance_methods.include?(:with_posthog_cable_context)
      abort 'channel hook missing' unless ActionCable::Channel::Base.private_instance_methods.include?(:with_posthog_cable_context)
    RUBY
    output, status = Open3.capture2e('bundle', 'exec', 'ruby', '-Ilib:posthog-rails/lib', '-e', script)
    expect(status.success?).to be(true), output
  end
end
