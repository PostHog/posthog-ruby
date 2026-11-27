# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Identity do
  let(:data) { PostHog::MCP::TrackingData.new(options: options, sink: nil) }
  let(:options) { PostHog::MCP::Options.new(identify: identify) }
  let(:identify) { ->(_request, _extra) { { distinct_id: 'user-1', properties: { role: 'developer' } } } }
  let(:request) { { method: 'tools/call', params: { name: 'add_todo', arguments: {} } } }

  it 'merges a later identity for the session into the cached one' do
    expect(described_class.resolve(data, 'ses_1', request, nil).to_h)
      .to eq(distinct_id: 'user-1', properties: { role: 'developer' }, groups: nil)

    data.options.instance_variable_set(:@identify, ->(_r, _e) { { distinct_id: 'user-2', groups: { org: 'o' } } })
    expect(described_class.resolve(data, 'ses_1', request, nil).to_h)
      .to eq(distinct_id: 'user-2', properties: { role: 'developer' }, groups: { org: 'o' })
  end

  {
    'a static identity' => [{ distinct_id: 'static' }, 'static'],
    'a 1-arity callable' => [->(req) { { distinct_id: req[:params][:name] } }, 'add_todo'],
    'a callable that raises' => [->(_r, _e) { raise 'nope' }, nil],
    'a callable that returns nil' => [->(_r, _e) {}, nil],
    'no identify option' => [nil, nil]
  }.each do |kind, (identify_option, distinct_id)|
    it "resolves #{kind}" do
      one = PostHog::MCP::TrackingData.new(options: PostHog::MCP::Options.new(identify: identify_option), sink: nil)
      expect(described_class.resolve(one, 'ses_1', request, nil)&.distinct_id).to eq(distinct_id)
    end
  end

  it 'hands back the identity it resolved, as a snapshot a later request cannot move' do
    actor = described_class.resolve(data, 'ses_1', request, nil)

    data.options.instance_variable_set(:@identify, ->(_r, _e) { { distinct_id: 'user-2' } })
    expect(described_class.resolve(data, 'ses_1', request, nil).distinct_id).to eq('user-2')
    expect(data.identified_sessions.get('ses_1').distinct_id).to eq('user-2')
    expect(actor.distinct_id).to eq('user-1')
  end

  it 'falls back to the cached identity when the callback yields nothing' do
    described_class.resolve(data, 'ses_1', request, nil)
    [->(_r, _e) { raise 'nope' }, ->(_r, _e) {}].each do |identify_option|
      data.options.instance_variable_set(:@identify, identify_option)
      expect(described_class.resolve(data, 'ses_1', request, nil).distinct_id).to eq('user-1')
    end
  end

  it 'keeps the identity cache consistent under concurrent identification' do
    concurrent = PostHog::MCP::TrackingData.new(
      options: PostHog::MCP::Options.new(identify: lambda { |req, _e|
        { distinct_id: 'user-1', properties: { req[:params][:name] => true } }
      }),
      sink: nil
    )
    threads = 16.times.map do |i|
      Thread.new do
        50.times do |j|
          described_class.resolve(concurrent, "ses_#{j % 4}", { params: { name: "t#{i}" } }, nil)
        end
      end
    end
    threads.each(&:join)
    expect(concurrent.identified_sessions.size).to eq(4)
    4.times do |j|
      identity = concurrent.identified_sessions.get("ses_#{j}")
      expect(identity.distinct_id).to eq('user-1')
      expect(identity.properties.keys.length).to eq(16)
    end
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
    expect do
      described_class.resolve(data, 'transport-session', conversation_id: '0198d3a7-1111-7222-8333-444455556666')
    end
      .not_to(change { data.session_id })
    expect(described_class.resolve(data, 'transport-session', conversation_id: '0198d3a7-1111-7222-8333-444455556666'))
      .to eq(%w[ses_57a5f3768678e803a4af9566ca8a661b conversation])
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

  it 'rolls only a generated session over, and only when asked after 30 idle minutes' do
    first, = described_class.resolve(data, nil)
    data.last_tool_call_end = Time.now - (31 * 60)
    expect(described_class.resolve(data, nil)[0]).to eq(first)
    described_class.start_tool_call(data)
    expect(described_class.resolve(data, nil)[0]).not_to eq(first)

    token = PostHog::MCP::SessionTokenPayload.new(session_id: 'ses_tok')
    described_class.resolve(data, nil, token: token)
    described_class.start_tool_call(data)
    expect(described_class.resolve(data, nil, token: token)[0]).to eq('ses_tok')
  end
end
