# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'rails/railtie'
require 'action_dispatch'
require 'rack/mock'
require 'timecop'

$LOAD_PATH.unshift File.expand_path('../../posthog-rails/lib', __dir__)

require 'posthog/rails'

RSpec.describe 'PostHog server wire snapshots' do
  # These values are constants so all golden artifacts share one deterministic clock and protocol version.
  # rubocop:disable Lint/ConstantDefinitionInBlock
  FIXED_TIME = Time.utc(2025, 1, 2, 3, 4, 5, 678_000)
  FIXED_VERSION = '0.0.0-snapshot'
  SNAPSHOT_FLAGS_ENDPOINT = 'https://us.i.posthog.com/flags/?v=2'
  QUERY_SECRET = 'query-secret-should-not-leak'
  AUTHORIZATION_SECRET = 'Bearer authorization-secret-should-not-leak'
  # rubocop:enable Lint/ConstantDefinitionInBlock

  def canonicalize(value)
    case value
    when Hash
      value.to_h { |key, nested_value| [key.to_s, canonicalize(nested_value)] }.sort.to_h
    when Array
      value.map { |nested_value| canonicalize(nested_value) }
    else
      value
    end
  end

  def expect_wire_snapshot(name, artifact)
    fixture_path = File.join(__dir__, 'fixtures', 'wire', "#{name}.json")
    expected = File.read(fixture_path)
    actual = "#{JSON.pretty_generate(canonicalize(artifact))}\n"

    expect(actual).to eq(expected)
  end

  before do
    stub_const('PostHog::VERSION', FIXED_VERSION)
    stub_const(
      'PostHog::Defaults::Request::HEADERS',
      PostHog::Defaults::Request::HEADERS.merge('User-Agent' => "posthog-ruby/#{FIXED_VERSION}").freeze
    )
  end

  around do |example|
    Timecop.freeze(FIXED_TIME) { example.run }
  end

  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }

  it 'matches the ordered capture, identify, alias, and group-identify event family' do
    client.capture(
      event: 'checkout completed',
      distinct_id: 'user-123',
      properties: {
        plan: 'enterprise',
        attempted_at: FIXED_TIME,
        line_items: [{ sku: 'ruby-book', quantity: 2 }]
      },
      groups: { company: 'company-123' },
      timestamp: FIXED_TIME,
      uuid: '00000000-0000-4000-8000-000000000001'
    )
    client.identify(
      distinct_id: 'user-123',
      properties: {
        email: 'person@example.test',
        profile: { role: 'admin', active: true }
      },
      timestamp: FIXED_TIME,
      uuid: '00000000-0000-4000-8000-000000000002'
    )
    client.alias(
      distinct_id: 'user-123',
      alias: 'anonymous-456',
      timestamp: FIXED_TIME,
      uuid: '00000000-0000-4000-8000-000000000003'
    )
    client.group_identify(
      group_type: 'company',
      group_key: 'company-123',
      distinct_id: 'user-123',
      properties: {
        name: 'Snapshot Industries',
        settings: { data_region: 'us', seats: 42 }
      },
      timestamp: FIXED_TIME,
      uuid: '00000000-0000-4000-8000-000000000004'
    )

    events = Array.new(4) { client.dequeue_last_message }
    transport = PostHog::Transport.new(compress_request: false)
    http = transport.instance_variable_get(:@http)
    response = instance_double(Net::HTTPResponse, code: '200', body: '{}')
    request_artifact = nil

    allow(response).to receive(:[]).with('Retry-After').and_return(nil)
    allow(http).to receive(:started?).and_return(true)
    allow(http).to receive(:request) do |request, payload|
      request_artifact = {
        body: JSON.parse(payload),
        headers: request.to_hash,
        method: request.method,
        path: request.path
      }
      response
    end

    expect(transport.send(API_KEY, events).status).to eq(200)
    expect_wire_snapshot('event_family', request_artifact)
  end

  it 'matches a complete deterministic exception event with ordered causes and frames' do
    stub_const('SnapshotRootError', Class.new(StandardError))
    stub_const('SnapshotWrapperError', Class.new(StandardError))

    root_error = SnapshotRootError.new('database unavailable')
    root_error.set_backtrace([
                               "/snapshot/app/lib/database.rb:17:in `query'",
                               "/snapshot/vendor/bundle/gems/framework/lib/framework.rb:88:in `call'"
                             ])
    wrapper_error = SnapshotWrapperError.new('request failed')
    wrapper_error.set_backtrace([
                                  "/snapshot/app/services/checkout.rb:31:in `submit'",
                                  "/snapshot/app/controllers/checkouts_controller.rb:12:in `create'"
                                ])
    wrapper_error.define_singleton_method(:cause) { root_error }

    allow(PostHog::ExceptionCapture).to receive(:project_root).and_return('/snapshot/app')
    allow(PostHog::ExceptionCapture).to receive(:dependency_roots).and_return(['/snapshot/vendor/bundle'])
    allow(SecureRandom).to receive(:uuid).and_return('00000000-0000-4000-8000-000000000005')

    client.capture_exception(
      wrapper_error,
      'user-123',
      { severity: 'error', request_id: 'request-789' },
      mechanism: { 'type' => 'snapshot', 'handled' => false }
    )

    expect_wire_snapshot('exception_event', client.dequeue_last_message)
  end

  it 'matches the maximal flags evaluation request body' do
    request = nil
    stub_request(:post, SNAPSHOT_FLAGS_ENDPOINT).to_return do |recorded_request|
      request = recorded_request
      { status: 200, body: { featureFlags: {} }.to_json }
    end

    client.evaluate_flags(
      'user-123',
      groups: { company: 'company-123', project: 'project-456' },
      person_properties: {
        email: 'person@example.test',
        plan: 'enterprise',
        signed_up_at: '2025-01-01T00:00:00Z'
      },
      group_properties: {
        company: { name: 'Snapshot Industries', seats: 42 },
        project: { name: 'Golden Tests', archived: false }
      },
      flag_keys: %i[checkout-redesign recommendations],
      disable_geoip: true
    )

    expect_wire_snapshot('flags_request', JSON.parse(request.body))
  end

  it 'matches Rails request context without leaking query or authorization values' do
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new

    app = lambda do |_env|
      client.capture(
        event: 'rails request',
        properties: { source: 'controller' },
        timestamp: FIXED_TIME,
        uuid: '00000000-0000-4000-8000-000000000006'
      )
      [200, { 'content-type' => 'text/plain' }, ['ok']]
    end
    env = Rack::MockRequest.env_for(
      "/private?token=#{QUERY_SECRET}",
      'REQUEST_METHOD' => 'GET',
      'REMOTE_ADDR' => '10.0.0.1',
      'HTTP_AUTHORIZATION' => AUTHORIZATION_SECRET,
      'HTTP_USER_AGENT' => 'Snapshot Browser',
      'HTTP_X_FORWARDED_FOR' => '203.0.113.10, 10.0.0.2',
      'HTTP_X_POSTHOG_DISTINCT_ID' => 'rails-user-123',
      'HTTP_X_POSTHOG_SESSION_ID' => 'rails-session-456'
    )

    PostHog::Rails::RequestContext.new(app).call(env)
    event = client.dequeue_last_message
    serialized_event = JSON.generate(event)

    expect(serialized_event).not_to include(QUERY_SECRET)
    expect(serialized_event).not_to include(AUTHORIZATION_SECRET)
    expect_wire_snapshot('rails_request_context_event', event)
  ensure
    PostHog::Rails.config = previous_config
  end
end
