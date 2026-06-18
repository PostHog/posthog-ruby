# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'rails/railtie'
require 'action_dispatch'
require 'rack/mock'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)

require 'posthog/rails'

RSpec.describe PostHog::Rails::RequestContext do
  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }

  around do |example|
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    example.run
  ensure
    PostHog::Rails.config = previous_config
  end

  def env_for(path = '/api/test', headers = nil, **header_keywords)
    headers = (headers || {}).merge(header_keywords)
    Rack::MockRequest.env_for(
      path,
      headers.merge(
        'REQUEST_METHOD' => 'POST',
        'REMOTE_ADDR' => '10.0.0.1'
      )
    )
  end

  def call_with(headers = nil, path: '/api/test', **header_keywords, &block)
    headers = (headers || {}).merge(header_keywords)
    app = lambda do |env|
      block.call(env)
      [200, { 'content-type' => 'text/plain' }, ['ok']]
    end

    described_class.new(app).call(env_for(path, headers))
  end

  it 'applies sanitized tracing headers and request metadata to downstream captures' do
    call_with(
      'HTTP_X_POSTHOG_DISTINCT_ID' => " frontend-user\n",
      'HTTP_X_POSTHOG_SESSION_ID' => " frontend-session\t",
      'HTTP_X_POSTHOG_WINDOW_ID' => 'window-123',
      'HTTP_USER_AGENT' => 'RSpec Agent',
      'HTTP_X_FORWARDED_FOR' => '203.0.113.10, 10.0.0.2'
    ) do
      client.capture(event: 'request_event')
    end

    message = client.dequeue_last_message
    expect(message[:distinct_id]).to eq('frontend-user')
    expect(message[:properties]['$session_id']).to eq('frontend-session')
    expect(message[:properties]).not_to have_key('$window_id')
    expect(message[:properties]['$current_url']).to include('/api/test')
    expect(message[:properties]['$request_method']).to eq('POST')
    expect(message[:properties]['$request_path']).to eq('/api/test')
    expect(message[:properties]['$user_agent']).to eq('RSpec Agent')
    expect(message[:properties]['$ip']).to eq('203.0.113.10')
  end

  it 'does not include query parameters in $current_url' do
    call_with(path: '/api/test?token=secret&email=user@example.com') do
      client.capture(event: 'query_event')
    end

    message = client.dequeue_last_message
    expect(message[:properties]['$current_url']).to include('/api/test')
    expect(message[:properties]['$current_url']).not_to include('?')
    expect(message[:properties]['$current_url']).not_to include('token=secret')
    expect(message[:properties]['$current_url']).not_to include('user@example.com')
  end

  it 'can disable tracing header capture while preserving request metadata' do
    PostHog::Rails.config.use_tracing_headers = false

    call_with(
      'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user',
      'HTTP_X_POSTHOG_SESSION_ID' => 'header-session',
      'HTTP_USER_AGENT' => 'RSpec Agent'
    ) do
      client.capture(event: 'opt_out_event')
    end

    message = client.dequeue_last_message
    expect(message[:distinct_id]).not_to eq('header-user')
    expect(message[:properties]['$session_id']).to be_nil
    expect(message[:properties]['$request_path']).to eq('/api/test')
    expect(message[:properties]['$user_agent']).to eq('RSpec Agent')
    expect(message[:properties]['$process_person_profile']).to be false
  end

  it 'prefers Rails trusted remote_ip over raw forwarded headers' do
    call_with(
      'action_dispatch.remote_ip' => '198.51.100.7',
      'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user',
      'HTTP_X_FORWARDED_FOR' => '203.0.113.10, 10.0.0.2'
    ) do
      client.capture(event: 'ip_event')
    end

    message = client.dequeue_last_message
    expect(message[:properties]['$ip']).to eq('198.51.100.7')
  end

  it 'lets explicit capture distinct_id and $session_id override tracing context' do
    call_with(
      'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user',
      'HTTP_X_POSTHOG_SESSION_ID' => 'header-session'
    ) do
      client.capture(
        event: 'override_event',
        distinct_id: 'explicit-user',
        properties: { '$session_id' => 'explicit-session' }
      )
    end

    message = client.dequeue_last_message
    expect(message[:distinct_id]).to eq('explicit-user')
    expect(message[:properties]['$session_id']).to eq('explicit-session')
  end

  it 'handles missing tracing headers without leaking identity or session' do
    call_with(
      'HTTP_X_POSTHOG_DISTINCT_ID' => 'first-user',
      'HTTP_X_POSTHOG_SESSION_ID' => 'first-session'
    ) do
      client.capture(event: 'first_request')
    end

    call_with do
      client.capture(event: 'second_request')
    end

    first = client.dequeue_last_message
    second = client.dequeue_last_message

    expect(first[:distinct_id]).to eq('first-user')
    expect(first[:properties]['$session_id']).to eq('first-session')
    expect(second[:distinct_id]).not_to eq('first-user')
    expect(second[:properties]['$session_id']).to be_nil
    expect(second[:properties]['$process_person_profile']).to be false
  end

  it 'supports case-insensitive and framework-normalized header names' do
    call_with(
      'x-posthog-distinct-id' => 'lower-user',
      'X-Posthog-Session-Id' => 'mixed-session'
    ) do
      client.capture(event: 'case_event')
    end

    message = client.dequeue_last_message
    expect(message[:distinct_id]).to eq('lower-user')
    expect(message[:properties]['$session_id']).to eq('mixed-session')
  end

  it 'ignores empty/control-only values and caps long values' do
    long_session_id = 's' * 1100

    call_with(
      'HTTP_X_POSTHOG_DISTINCT_ID' => " \u0000\n\t ",
      'HTTP_X_POSTHOG_SESSION_ID' => " #{long_session_id}\n"
    ) do
      client.capture(event: 'sanitized_event')
    end

    message = client.dequeue_last_message
    expect(message[:distinct_id]).to be_a(String)
    expect(message[:distinct_id]).not_to eq("\u0000")
    expect(message[:properties]['$process_person_profile']).to be false
    expect(message[:properties]['$session_id']).to eq('s' * 1000)
  end

  it 'prefers authenticated Rails user context over tracing headers for exceptions' do
    PostHog::Rails.config.auto_capture_exceptions = true

    allow(PostHog).to receive(:capture_exception) do |exception, distinct_id, properties|
      client.capture_exception(exception, distinct_id, properties)
    end

    user = Struct.new(:id).new('rails-user')
    controller_class = Class.new do
      def initialize(user)
        @user = user
      end

      def controller_name
        'posts'
      end

      def action_name
        'show'
      end

      private

      def current_user
        @user
      end
    end

    app = lambda do |env|
      env['action_controller.instance'] = controller_class.new(user)
      raise StandardError, 'boom'
    end
    middleware = described_class.new(PostHog::Rails::CaptureExceptions.new(app))

    expect do
      middleware.call(
        env_for(
          '/boom',
          'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user',
          'HTTP_X_POSTHOG_SESSION_ID' => 'exception-session'
        )
      )
    end.to raise_error(StandardError, 'boom')

    message = client.dequeue_last_message
    expect(message[:event]).to eq('$exception')
    expect(message[:distinct_id]).to eq('rails-user')
    expect(message[:properties]['$session_id']).to eq('exception-session')
  end

  it 'supports current_user_resolver variants for exceptions' do
    PostHog::Rails.config.auto_capture_exceptions = true

    current_class = Class.new do
      class << self
        attr_accessor :user
      end
    end
    stub_const('Current', current_class)
    Current.user = Struct.new(:id).new('current-user')

    user = Struct.new(:id).new('resolved-user')
    controller_class = Class.new do
      attr_reader :posthog_user

      def initialize(user)
        @posthog_user = user
      end

      def controller_name
        'posts'
      end

      def action_name
        'show'
      end
    end

    allow(PostHog).to receive(:capture_exception) do |exception, distinct_id, properties|
      client.capture_exception(exception, distinct_id, properties)
    end

    [
      {
        description: 'without arguments',
        resolver: proc { Current.user },
        controller: nil,
        expected_distinct_id: 'current-user'
      },
      {
        description: 'with a controller argument',
        resolver: proc(&:posthog_user),
        controller: controller_class.new(user),
        expected_distinct_id: 'resolved-user'
      },
      {
        description: 'with a controller argument but no controller',
        resolver: proc(&:posthog_user),
        controller: nil,
        expected_distinct_id: 'header-user'
      },
      {
        description: 'when the resolver raises',
        resolver: proc { raise 'resolver failed' },
        controller: nil,
        expected_distinct_id: 'header-user'
      }
    ].each do |scenario|
      PostHog::Rails.config.current_user_resolver = scenario.fetch(:resolver)

      app = lambda do |env|
        env['action_controller.instance'] = scenario[:controller] if scenario[:controller]
        raise StandardError, "boom #{scenario.fetch(:description)}"
      end
      middleware = described_class.new(PostHog::Rails::CaptureExceptions.new(app))

      expect do
        middleware.call(
          env_for(
            '/boom',
            'HTTP_X_POSTHOG_DISTINCT_ID' => 'header-user',
            'HTTP_X_POSTHOG_SESSION_ID' => 'exception-session'
          )
        )
      end.to raise_error(StandardError, "boom #{scenario.fetch(:description)}")

      message = client.dequeue_last_message
      expect(message[:event]).to eq('$exception')
      expect(message[:distinct_id]).to eq(scenario.fetch(:expected_distinct_id))
      expect(message[:properties]['$session_id']).to eq('exception-session')
    end
  end

  it 'captures exceptions with tracing context and re-raises' do
    PostHog::Rails.config.auto_capture_exceptions = true

    allow(PostHog).to receive(:capture_exception) do |exception, distinct_id, properties|
      client.capture_exception(exception, distinct_id, properties)
    end

    app = lambda do |_env|
      raise StandardError, 'boom'
    end
    middleware = described_class.new(PostHog::Rails::CaptureExceptions.new(app))

    expect do
      middleware.call(
        env_for(
          '/boom',
          'HTTP_X_POSTHOG_DISTINCT_ID' => 'exception-user',
          'HTTP_X_POSTHOG_SESSION_ID' => 'exception-session',
          'HTTP_USER_AGENT' => 'Exception Agent'
        )
      )
    end.to raise_error(StandardError, 'boom')

    message = client.dequeue_last_message
    expect(message[:event]).to eq('$exception')
    expect(message[:distinct_id]).to eq('exception-user')
    expect(message[:properties]['$session_id']).to eq('exception-session')
    expect(message[:properties]['$request_path']).to eq('/boom')
    expect(message[:properties]['$user_agent']).to eq('Exception Agent')
  end

  it 'disables tracing headers for exceptions while preserving request metadata' do
    PostHog::Rails.config.auto_capture_exceptions = true
    PostHog::Rails.config.use_tracing_headers = false

    allow(PostHog).to receive(:capture_exception) do |exception, distinct_id, properties|
      client.capture_exception(exception, distinct_id, properties)
    end

    app = lambda do |_env|
      raise StandardError, 'boom'
    end
    middleware = described_class.new(PostHog::Rails::CaptureExceptions.new(app))

    expect do
      middleware.call(
        env_for(
          '/boom',
          'HTTP_X_POSTHOG_DISTINCT_ID' => 'disabled-header-user',
          'HTTP_USER_AGENT' => 'Disabled Context Agent',
          'HTTP_X_FORWARDED_FOR' => '203.0.113.11, 10.0.0.2'
        )
      )
    end.to raise_error(StandardError, 'boom')

    message = client.dequeue_last_message
    expect(message[:event]).to eq('$exception')
    expect(message[:distinct_id]).not_to eq('disabled-header-user')
    expect(message[:properties]['$process_person_profile']).to be false
    expect(message[:properties]['$request_path']).to eq('/boom')
    expect(message[:properties]['$user_agent']).to eq('Disabled Context Agent')
    expect(message[:properties]['$ip']).to eq('203.0.113.11')
  end
end
