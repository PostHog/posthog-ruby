# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::SessionToken do
  let(:frozen) { 'eyJzaWQiOiJzZXNfZml4dHVyZSIsImNuIjoiQ2xhdWRlIENvZGUiLCJjdiI6IjEuMi4zIiwicHYiOiIyMDI1LTA2LTE4In0' }

  def wire(value)
    Base64.urlsafe_encode64(JSON.generate(value), padding: false)
  end

  it 'encodes the frozen cross-SDK wire format' do
    payload = PostHog::MCP::SessionTokenPayload.new(session_id: 'ses_fixture', client_name: 'Claude Code',
                                                    client_version: '1.2.3', protocol_version: '2025-06-18')
    expect(described_class.encode(payload)).to eq(frozen)
    expect(PostHog::MCP.encode_session_id(session_id: 'ses_fixture', client_name: 'Claude Code',
                                          client_version: '1.2.3', protocol_version: '2025-06-18')).to eq(frozen)
  end

  it 'round-trips, omits absent fields, and clamps client fields to 200 chars' do
    token = described_class.encode(session_id: 'ses_0199aabb')
    expect(JSON.parse(Base64.urlsafe_decode64(token))).to eq('sid' => 'ses_0199aabb')
    expect(described_class.decode(token).to_h).to eq(session_id: 'ses_0199aabb', client_name: nil, client_version: nil,
                                                     protocol_version: nil)

    token = described_class.encode(session_id: 'ses_x', client_name: 'a' * 500, client_version: 'b' * 500,
                                   protocol_version: 'c' * 500)
    expect(JSON.parse(Base64.urlsafe_decode64(token))).to eq(
      'sid' => 'ses_x', 'cn' => 'a' * 200, 'cv' => 'b' * 200, 'pv' => 'c' * 200
    )
    decoded = described_class.decode(wire({ sid: 'ses_x', cn: 'a' * 500, cv: 'b' * 500, pv: 'c' * 500 }))
    expect(decoded.to_h).to eq(session_id: 'ses_x', client_name: 'a' * 200, client_version: 'b' * 200,
                               protocol_version: 'c' * 200)

    token = described_class.encode(session_id: 'ses_0199aabb', client_name: 'Клиент 😀 客户端', client_version: '1.0')
    expect(token).to match(/\A[A-Za-z0-9_-]+\z/)
    expect(described_class.decode(token).client_name).to eq('Клиент 😀 客户端')
  end

  it 'rejects an empty session id on encode' do
    expect { described_class.encode(session_id: '') }.to raise_error(ArgumentError)
  end

  it 'returns nil for anything that is not one of our tokens' do
    [
      '550e8400-e29b-41d4-a716-446655440000', 'ses_0199aabbccdd', 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig',
      'aaa.bbb.ccc', 'not a token!', Base64.urlsafe_encode64('not json at all', padding: false), '', nil, 42, ['a'],
      'A' * 5000, wire(['ses_x']), wire('ses_x'), wire(nil), wire({ cn: 'no sid' }), wire({ sid: 42 }),
      wire({ sid: '' }), wire({ sid: 'x' * 200 })
    ].each do |value|
      expect(described_class.decode(value)).to be_nil, "expected nil for #{value.inspect[0, 40]}"
    end
    huge = wire({ sid: 'ses_x', cn: 'y' * 8000 })
    expect(huge.length).to be > 4096
    expect(described_class.decode(huge)).to be_nil
  end

  it 'accepts a 128-character session id but rejects 129 characters' do
    expect(described_class.decode(wire({ sid: 's' * 128 })).session_id).to eq('s' * 128)
    expect(described_class.decode(wire({ sid: 's' * 129 }))).to be_nil
  end

  it 'drops malformed client fields but keeps the session id' do
    decoded = described_class.decode(wire({ sid: 'ses_x', cn: 42, cv: {} }))
    expect(decoded.session_id).to eq('ses_x')
    expect(decoded.client_name).to be_nil
    expect(decoded.client_version).to be_nil
  end

  describe '.read_header' do
    it 'reads case-insensitively, takes the first array element, trims, and rejects blanks' do
      expect(described_class.read_header('mcp-session-id' => 'abc')).to eq('abc')
      expect(described_class.read_header('Mcp-Session-Id' => 'abc')).to eq('abc')
      expect(described_class.read_header('mcp-session-id' => %w[abc def])).to eq('abc')
      expect(described_class.read_header('Mcp-Session-Id' => '  tok  ')).to eq('tok')
      expect(described_class.read_header({})).to be_nil
      expect(described_class.read_header('mcp-session-id' => '')).to be_nil
      expect(described_class.read_header('mcp-session-id' => '   ')).to be_nil
      expect(described_class.read_header('mcp-session-id' => 42)).to be_nil
      expect(described_class.read_header(nil)).to be_nil
      expect(described_class.read_header('headers')).to be_nil
    end
  end
end
