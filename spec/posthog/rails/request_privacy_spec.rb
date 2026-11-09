# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'rails/railtie'
require 'action_dispatch'
require 'rack/mock'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'

RSpec.describe 'Rails exception request privacy' do
  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }
  let(:error) { StandardError.new('application failure') }
  let(:private_value) { SecureRandom.uuid }
  let(:sensitive_properties) do
    %w[$request_params $request_headers $request_cookies $request_body $execution_context $referrer]
  end

  around do |example|
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails.config.auto_capture_exceptions = true
    example.run
  ensure
    PostHog::Rails.config = previous_config
    client.shutdown
  end

  before do
    allow(PostHog).to receive(:client).and_return(client)
  end

  def request_env(body = '', content_type = 'application/json')
    Rack::MockRequest.env_for(
      "/orders?email=#{private_value}",
      method: 'POST',
      input: body.gsub('PRIVATE_VALUE', private_value),
      'CONTENT_TYPE' => content_type,
      'HTTP_AUTHORIZATION' => private_value,
      'HTTP_COOKIE' => "token=#{private_value}",
      'HTTP_REFERER' => "https://example.com/?token=#{private_value}",
      'HTTP_USER_AGENT' => 'RSpec Agent',
      'HTTP_X_POSTHOG_DISTINCT_ID' => 'request-user'
    )
  end

  def capture_request(env)
    app = ->(_env) { raise error }
    middleware = PostHog::Rails::RequestContext.new(PostHog::Rails::CaptureExceptions.new(app))
    expect { middleware.call(env) }.to raise_error(error)
    client.dequeue_last_message
  end

  it 'does not expose sensitive request collection options' do
    options = %i[exception_request_headers exception_request_cookies exception_request_body]
    expect(PostHog::Rails.config).not_to respond_to(*options, *options.map { |option| :"#{option}=" })
  end

  {
    'application/json' => '{"email":"PRIVATE_VALUE"}',
    'application/x-www-form-urlencoded' => 'email=PRIVATE_VALUE',
    'text/plain' => 'PRIVATE_VALUE'
  }.each do |content_type, body|
    it "captures the exception without collecting #{content_type} request data" do
      event = capture_request(request_env(body, content_type))

      expect(event[:distinct_id]).to eq('request-user')
      expect(event[:properties]).to include(
        '$request_method' => 'POST', '$request_path' => '/orders',
        '$user_agent' => 'RSpec Agent', '$exception_list' => an_instance_of(Array)
      )
      expect(event[:properties].keys).not_to include(*sensitive_properties)
      expect(JSON.generate(event)).not_to include(private_value)
    end
  end

  it 'does not collect parameters already parsed by Rails' do
    env = request_env
    env['action_dispatch.request.parameters'] = { 'email' => private_value }
    env['action_dispatch.request.request_parameters'] = { 'email' => private_value }

    properties = capture_request(env)[:properties]

    expect(properties.keys).not_to include(*sensitive_properties)
    expect(JSON.generate(properties)).not_to include(private_value)
  end

  it 'does not read request input when capturing an exception' do
    env = request_env('{"email":"PRIVATE_VALUE"}')
    input = env['rack.input']
    input.pos = 4
    expect(input).not_to receive(:read)
    expect(input).not_to receive(:seek)

    expect(capture_request(env)[:properties]).to have_key('$exception_list')
    expect(input.pos).to eq(4)
  end

  it 'captures malformed JSON without invoking Rails parameter parsers or logging its contents' do
    body = '{"email":"PRIVATE_VALUE"'
    env = request_env(body)
    diagnostics = StringIO.new
    env['action_dispatch.logger'] = Logger.new(diagnostics)
    expect_any_instance_of(ActionDispatch::Request).not_to receive(:params)
    expect_any_instance_of(ActionDispatch::Request).not_to receive(:query_parameters)
    expect_any_instance_of(ActionDispatch::Request).not_to receive(:request_parameters)

    event = capture_request(env)

    expect(event[:properties]).to have_key('$exception_list')
    expect(event[:properties].keys).not_to include(*sensitive_properties)
    expect(diagnostics.string).not_to include(private_value)
    expect(env['rack.input'].pos).to eq(0)
  end

  it 'does not inspect ambient Rails execution context on request or reporter exceptions' do
    execution_context = double('execution context')
    stub_const('ActiveSupport::ExecutionContext', execution_context)
    expect(execution_context).not_to receive(:to_h)

    expect(capture_request(request_env)[:properties]).not_to have_key('$execution_context')

    PostHog::Rails::ErrorSubscriber.new.report(
      StandardError.new('reported failure'), handled: true, severity: :error, context: {}
    )
    expect(client.dequeue_last_message[:properties]).not_to have_key('$execution_context')
  end
end
