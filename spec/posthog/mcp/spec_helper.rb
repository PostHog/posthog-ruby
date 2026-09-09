# frozen_string_literal: true

require 'spec_helper'
require 'posthog/mcp'

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

  def new_test_client
    PostHog::Client.new(api_key: 'phc_test', test_mode: true)
  end
end

RSpec.configure do |config|
  config.include MCPSpecHelpers
  config.before(:each) { PostHog::MCP.reset_for_tests! }
end
