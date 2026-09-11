# frozen_string_literal: true

# Minimal stdio MCP server instrumented with PostHog MCP analytics (experimental).
#
#   POSTHOG_API_KEY=phc_... bundle exec ruby examples/mcp_server.rb
#
# Then paste JSON-RPC lines on stdin, for example:
#
#   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18",
#     "capabilities":{},"clientInfo":{"name":"demo","version":"1.0"}}}
#   {"jsonrpc":"2.0","id":2,"method":"tools/list"}
#   {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"greet",
#     "arguments":{"name":"Ada","context":"Greeting a user to test the demo server."}}}
#
# (each request on a single line). Without POSTHOG_API_KEY the client runs in test
# mode and the captured events are dumped to stderr on exit.

require 'bundler/setup'
require 'json'
require 'logger'
require 'mcp'
require 'posthog/mcp'

# stdout belongs to the MCP protocol; keep every log line on stderr.
PostHog::Logging.logger = Logger.new($stderr)

api_key = ENV.fetch('POSTHOG_API_KEY', nil)
posthog = PostHog::Client.new(api_key: api_key || 'phc_test', test_mode: api_key.nil?)

server = MCP::Server.new(name: 'posthog-demo', version: '0.1.0')
server.define_tool(name: 'greet', description: 'Greets someone by name',
                   input_schema: { properties: { name: { type: 'string' } }, required: ['name'] }) do |name:, **|
  MCP::Tool::Response.new([{ type: 'text', text: "Hello, #{name}!" }])
end
server.define_tool(name: 'fail', description: 'Always raises, to demonstrate error capture') do |**|
  raise 'Something went wrong'
end

PostHog::MCP.instrument(server, posthog, report_missing: true,
                                         logger: ->(message) { warn "[mcp-analytics] #{message}" })

if api_key.nil?
  at_exit do
    while posthog.queued_messages.positive?
      message = posthog.dequeue_last_message
      warn JSON.pretty_generate(event: message[:event], distinct_id: message[:distinct_id],
                                properties: message[:properties])
    end
  end
else
  at_exit { posthog.shutdown }
end

MCP::Server::Transports::StdioTransport.new(server).open
