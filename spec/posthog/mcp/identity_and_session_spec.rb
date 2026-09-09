# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Identity do
  let(:data) { PostHog::MCP::TrackingData.new(options: options, sink: nil) }
  let(:options) { PostHog::MCP::Options.new(identify: identify) }
  let(:identify) { ->(_request, _extra) { { distinct_id: 'user-1', properties: { role: 'developer' } } } }
  let(:request) { { method: 'tools/call', params: { name: 'add_todo', arguments: {} } } }

  it 'fires $identify once per session and again only on material change' do
    event = described_class.handle_identify(data, 'ses_1', request, { 'session_id' => 'abc', 'session' => Object.new })
    expect(event['event_type']).to eq('posthog:identify')
    expect(event['resource_name']).to eq('add_todo')
    expect(event['parameters']['extra']).to eq('session_id' => 'abc')
    expect(described_class.handle_identify(data, 'ses_1', request, nil)).to be_nil
    expect(data.identified_sessions.get('ses_1').to_h).to eq(distinct_id: 'user-1', properties: { role: 'developer' },
                                                             groups: nil)

    data.options.instance_variable_set(:@identify, ->(_r, _e) { { distinct_id: 'user-2', groups: { org: 'o' } } })
    changed = described_class.handle_identify(data, 'ses_1', request, nil)
    expect(changed).not_to be_nil
    merged = data.identified_sessions.get('ses_1')
    expect(merged.distinct_id).to eq('user-2')
    expect(merged.properties).to eq(role: 'developer')
    expect(merged.groups).to eq(org: 'o')
  end

  it 'accepts static identities, 1-arity callables, and swallows errors and nils' do
    static = PostHog::MCP::TrackingData.new(options: PostHog::MCP::Options.new(identify: { distinct_id: 'static' }),
                                            sink: nil)
    expect(described_class.handle_identify(static, 'ses_1', request, nil)['session_id']).to eq('ses_1')
    one = PostHog::MCP::TrackingData.new(options: PostHog::MCP::Options.new(identify: lambda { |req|
      { distinct_id: req[:params][:name] }
    }), sink: nil)
    described_class.handle_identify(one, 'ses_1', request, nil)
    expect(one.identified_sessions.get('ses_1').distinct_id).to eq('add_todo')
    boom = PostHog::MCP::TrackingData.new(options: PostHog::MCP::Options.new(identify: lambda { |_r, _e|
      raise 'nope'
    }), sink: nil)
    expect(described_class.handle_identify(boom, 'ses_1', request, nil)).to be_nil
    nils = PostHog::MCP::TrackingData.new(options: PostHog::MCP::Options.new(identify: ->(_r, _e) {}), sink: nil)
    expect(described_class.handle_identify(nils, 'ses_1', request, nil)).to be_nil
  end

  it 'bounds the identity cache as an LRU' do
    cache = PostHog::MCP::IdentityCache.new(2)
    cache.set('a', 1)
    cache.set('b', 2)
    cache.get('a')
    cache.set('c', 3)
    expect(cache.has?('b')).to be(false)
    expect(cache.has?('a')).to be(true)
    expect(cache.size).to eq(2)
  end
end

RSpec.describe PostHog::MCP::Session do
  let(:data) { PostHog::MCP::TrackingData.new(options: PostHog::MCP::Options.new, sink: nil) }

  it 'anchors on an echoed conversation id without touching shared state' do
    expect(described_class.resolve(data, 'transport-session', conversation_id: '0198d3a7-1111-7222-8333-444455556666'))
      .to eq(%w[ses_57a5f3768678e803a4af9566ca8a661b conversation])
    expect(data.session_id).to be_nil
  end

  it 'uses a token session verbatim, hashes transport sessions stickily, and generates otherwise' do
    token = PostHog::MCP::SessionTokenPayload.new(session_id: 'ses_tok')
    expect(described_class.resolve(data, 'ignored-raw', token: token)).to eq(%w[ses_tok token])
    generated, source = described_class.resolve(data, nil)
    expect(source).to eq('generated')
    expect(generated).not_to eq('ses_tok')

    expect(described_class.resolve(data,
                                   'mcp-123')).to eq([PostHog::MCP.derive_session_id_from_mcp_session('mcp-123'),
                                                      'mcp'])
    expect(described_class.resolve(data,
                                   nil)).to eq([PostHog::MCP.derive_session_id_from_mcp_session('mcp-123'), 'mcp'])
  end

  it 'rolls generated sessions over after 30 minutes of inactivity' do
    first, = described_class.resolve(data, nil)
    expect(described_class.resolve(data, nil)[0]).to eq(first)
    data.last_activity = Time.now - (31 * 60)
    expect(described_class.resolve(data, nil)[0]).not_to eq(first)
    token = PostHog::MCP::SessionTokenPayload.new(session_id: 'ses_tok')
    described_class.resolve(data, nil, token: token)
    data.last_activity = Time.now - (31 * 60)
    expect(described_class.resolve(data, nil, token: token)[0]).to eq('ses_tok')
  end
end
