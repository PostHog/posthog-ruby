# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Sanitization do
  binary = '[binary data redacted - not supported by PostHog MCP analytics]'

  describe '.sanitize_captured_value' do
    it 'redacts sensitive keys and PostHog tokens' do
      expect(described_class.sanitize_captured_value('authorization' => 'Bearer x', 'api_key' => 'k', 'safe' => 'keep'))
        .to eq('authorization' => '[redacted]', 'api_key' => '[redacted]', 'safe' => 'keep')
      value = 'Default project token api_token: phc_123456789012345678901234567890.'
      expect(described_class.sanitize_captured_value(value)).to eq('Default project token api_token: [redacted].')
    end

    it 'redacts base64-looking strings at and above the size gate only' do
      expect(described_class.sanitize_captured_value("#{'A' * 10_239}=")).to eq(binary)
      expect(described_class.sanitize_captured_value("#{'A' * 10_238}=")).to eq("#{'A' * 10_238}=")
      expect(described_class.sanitize_captured_value("data:image/png;base64,#{'A' * 12_000}")).to eq(binary)
      expect(described_class.sanitize_captured_value("#{'A-_' * 4000}=")).to eq(binary)
      prose = 'Hello, world! This is NOT base64. ' * 400
      expect(described_class.sanitize_captured_value(prose)).to eq(prose)
      expect(described_class.sanitize_captured_value('level1' => { 'data' => 'A' * 11_000 }))
        .to eq('level1' => { 'data' => binary })
    end

    it 'passes non-strings through and redacts other vendors\' credentials per word' do
      expect(described_class.sanitize_captured_value(42)).to eq(42)
      expect(described_class.sanitize_captured_value(true)).to eq(true)
      redacted = described_class.sanitize_captured_value('auth failed for sk-proj-abc123XYZ789defGHI456jklMNO012pqr')
      expect(redacted).to start_with('auth failed for')
      expect(redacted).not_to include('sk-proj-')
      expect(described_class.sanitize_captured_value('revenue warehouse unreachable (period=q3)'))
        .to eq('revenue warehouse unreachable (period=q3)')
    end
  end

  describe '.build_captured_mcp_parameters' do
    it 'keeps id/jsonrpc/method/params, strips injected arguments, and drops everything else' do
      request = {
        id: 102, jsonrpc: '2.0', method: 'tools/call',
        params: { name: 'projects-get',
                  arguments: { context: 'Review local project access.', projectId: 1,
                               api_token: 'phc_123456789012345678901234567890' } },
        extra: { headers: { authorization: 'Bearer phx_123456789012345678901234567890' } }
      }
      expect(described_class.build_captured_mcp_parameters(request)).to eq(
        'request' => { 'id' => 102, 'jsonrpc' => '2.0', 'method' => 'tools/call',
                       'params' => { 'name' => 'projects-get',
                                     'arguments' => { 'projectId' => 1, 'api_token' => '[redacted]' } } }
      )
    end
  end

  describe '.sanitize_response' do
    it 'redacts non-text content blocks with the exact placeholders' do
      response = {
        'content' => [
          { 'type' => 'text', 'text' => 'Hello world' },
          { 'type' => 'image', 'data' => 'base64imagedata...', 'mimeType' => 'image/png' },
          { 'type' => 'audio', 'data' => 'base64audiodata...', 'mimeType' => 'audio/wav' },
          { 'type' => 'resource',
            'resource' => { 'uri' => 'file:///data.bin', 'blob' => 'x', 'mimeType' => 'application/octet-stream' } },
          { 'type' => 'resource',
            'resource' => { 'uri' => 'file:///readme.txt', 'text' => 'This is a text resource' } },
          { 'type' => 'video', 'data' => 'somestuff', 'mimeType' => 'video/mp4' },
          { 'type' => 'resource_link', 'uri' => 'file:///some/resource', 'name' => 'My Resource' }
        ],
        'structuredContent' => { 'project' => 'Default project',
                                 'api_token' => 'phc_123456789012345678901234567890' }
      }
      sanitized = described_class.sanitize_response(response)
      expect(sanitized['content']).to eq([
                                           { 'type' => 'text', 'text' => 'Hello world' },
                                           { 'type' => 'text',
                                             'text' => '[image content redacted - not supported by PostHog MCP analytics]' },
                                           { 'type' => 'text',
                                             'text' => '[audio content redacted - not supported by PostHog MCP analytics]' },
                                           { 'type' => 'text',
                                             'text' => '[binary resource content redacted - not supported by PostHog MCP analytics]' },
                                           { 'type' => 'resource',
                                             'resource' => { 'uri' => 'file:///readme.txt',
                                                             'text' => 'This is a text resource' } },
                                           { 'type' => 'text',
                                             'text' => '[unsupported content type "video" redacted - not supported by PostHog MCP analytics]' },
                                           { 'type' => 'resource_link', 'uri' => 'file:///some/resource',
                                             'name' => 'My Resource' }
                                         ])
      expect(sanitized['structuredContent']).to eq('project' => 'Default project', 'api_token' => '[redacted]')
      expect(response['structuredContent']['api_token']).to start_with('phc_') # never mutated
    end
  end

  describe '.redact_pii' do
    nbsp = ' '
    nnbsp = ' '
    {
      'Looking up orders for jane.doe@acme.co.uk before refunding.' => 'Looking up orders for [redacted] before refunding.',
      "from #{'a' * 64}@example.com now" => 'from [redacted] now',
      'Blocking traffic from 203.0.113.42 after abuse.' => 'Blocking traffic from [redacted] after abuse.',
      'Tracing request from 2001:db8::ff00:42:8329 across the mesh.' =>
        'Tracing request from [redacted] across the mesh.',
      'Routing host 2001:db8:: for now.' => 'Routing host [redacted] for now.',
      'Health check from ::1 passed.' => 'Health check from [redacted] passed.',
      'Reference ticket for number 415-555-0142 escalation.' =>
        'Reference ticket for number [redacted] escalation.',
      'Call the customer on 415/555/0142 today.' => 'Call the customer on [redacted] today.',
      'Calling back on +1 (415) 555-0142 about the outage.' => 'Calling back on [redacted] about the outage.',
      'Reaching them at (415)555-0142 today.' => 'Reaching them at [redacted] today.',
      'Ring +44 (0) 20 7946 0958 please.' => 'Ring [redacted] please.',
      "Calling the customer on 415#{nnbsp}555#{nnbsp}0132 today." => 'Calling the customer on [redacted] today.',
      'Charging the saved card 4111 1111 1111 1111 for the renewal.' =>
        'Charging the saved card [redacted] for the renewal.',
      'Charging card 4111.1111.1111.1111 today.' => 'Charging card [redacted] today.',
      'Charging card 4111/1111/1111/1111 today.' => 'Charging card [redacted] today.',
      "Charging card 4111#{nbsp}1111#{nbsp}1111#{nbsp}1111 now." => 'Charging card [redacted] now.',
      'Charging card 4111 1111 1111 1111 12/30 for renewal.' => 'Charging card [redacted] 12/30 for renewal.',
      'Moving funds 4111 1111 1111 1111 5555 5555 5555 4444 now.' => 'Moving funds [redacted] [redacted] now.',
      'Verifying SSN 123-45-6789 for the claim.' => 'Verifying SSN [redacted] for the claim.',
      'Verifying SSN 123 45 6789 for the claim.' => 'Verifying SSN [redacted] for the claim.',
      'Verifying SSN 123.45.6789 for the claim.' => 'Verifying SSN [redacted] for the claim.',
      'Emailing bob@example.com and calling +1-202-555-0170 about the issue.' =>
        'Emailing [redacted] and calling [redacted] about the issue.'
    }.each do |input, expected|
      it "redacts #{input.inspect}" do
        expect(described_class.redact_pii(input)).to eq(expected)
      end
    end

    [
      'Fetching record 4155550142 from the ledger service.',
      'Looking up record 123456789 in the ledger.',
      'Correlating with order 1234567890123456 in the warehouse.',
      'Deploying at 2024-01-15 12:30 UTC after review.',
      'Upgrading to build 2024.11.05.1830 for the team.',
      'Calling std::bad and std::vector helpers for the team.',
      'Upgrading to v1.2.3 on 2024-01-15 by refactoring std::vector usage.',
      'Searching the organization repositories to prioritize open performance issues.'
    ].each do |input|
      it "leaves #{input.inspect} untouched" do
        expect(described_class.redact_pii(input)).to eq(input)
      end
    end

    it 'handles pathological input quickly and passes non-strings through' do
      pathological = "#{'a' * 50_000}@#{'a' * 50_000}"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(described_class.redact_pii(pathological)).to eq(pathological)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
      expect(described_class.redact_pii(123)).to eq(123)
    end
  end

  describe '.sanitize_event' do
    it 'redacts PII in the intent only, and tokens in exception values' do
      event = {
        'user_intent' => 'Rotating token phc_123456789012345678901234567890 for user carol@example.org.',
        'parameters' => { 'email' => 'dave@example.com', 'ip' => '203.0.113.42' },
        'response' => { 'content' => [{ 'type' => 'text', 'text' => 'Matched dave@example.com at 203.0.113.42.' }] },
        'error' => { '$exception_list' => [{ 'type' => 'Error',
                                             'value' => 'Project token phc_123456789012345678901234567890' }] }
      }
      sanitized = described_class.sanitize_event(event)
      expect(sanitized['user_intent']).to eq('Rotating token [redacted] for user [redacted].')
      expect(sanitized['parameters']).to eq('email' => 'dave@example.com', 'ip' => '203.0.113.42')
      expect(sanitized['response']['content'][0]['text']).to eq('Matched dave@example.com at 203.0.113.42.')
      expect(sanitized['error']['$exception_list'][0]['value']).to eq('Project token [redacted]')
      expect(event['error']['$exception_list'][0]['value']).to include('phc_')
    end
  end
end
# rubocop:enable Layout/LineLength
