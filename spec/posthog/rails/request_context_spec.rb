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
    expect(message[:properties]['$window_id']).to eq('window-123')
    expect(message[:properties]['$current_url']).to include('/api/test')
    expect(message[:properties]['$request_method']).to eq('POST')
    expect(message[:properties]['$request_path']).to eq('/api/test')
    expect(message[:properties]['$user_agent']).to eq('RSpec Agent')
    expect(message[:properties]['$ip']).to eq('203.0.113.10')
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

  it 'captures exceptions with tracing context and re-raises' do
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new
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
  ensure
    PostHog::Rails.config = previous_config
  end
end
