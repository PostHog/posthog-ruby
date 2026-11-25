# frozen_string_literal: true

require 'spec_helper'
require 'posthog/mcp'
require 'stringio'

module MCPSpecHelpers
  def drain_events(client)
    events = []
    events << client.dequeue_last_message while client.queued_messages.positive?
    events
  end

  def events_named(events, name)
    events.select { |event| event[:event] == name }
  end

  def rpc(id, method, params = nil)
    request = { jsonrpc: '2.0', id: id, method: method }
    request[:params] = params unless params.nil?
    request
  end

  # A Rack env for a POST to the Streamable HTTP transport.
  def env_for(body, headers = {})
    env = {
      'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/', 'SCRIPT_NAME' => '', 'QUERY_STRING' => '',
      'SERVER_NAME' => 'localhost', 'SERVER_PORT' => '80', 'HTTP_HOST' => 'localhost', 'rack.url_scheme' => 'http',
      'HTTP_ACCEPT' => 'application/json, text/event-stream', 'CONTENT_TYPE' => 'application/json',
      'rack.input' => StringIO.new(JSON.generate(body)), 'rack.errors' => StringIO.new
    }
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    env
  end

  def parse(response)
    JSON.parse(response[2].respond_to?(:join) ? response[2].join : response[2].to_s)
  end

  def new_test_client
    PostHog::Client.new(api_key: 'phc_test', test_mode: true)
  end
end

RSpec.configure do |config|
  config.include MCPSpecHelpers
  config.before(:each) { PostHog::MCP.reset_for_tests! }
end
