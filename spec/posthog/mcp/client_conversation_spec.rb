# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::ClientConversation do
  let(:chatgpt) { described_class.recognize('openai-mcp/1.0.0 (ChatGPT)', nil) }
  let(:codex) { described_class.recognize(nil, 'codex-mcp-client') }

  {
    'a printable ChatGPT id' => ['openai/session', 'v1/conv-1', 'openai/session:v1/conv-1'],
    'a ChatGPT id with invalid UTF-8 bytes' => ['openai/session', "v1/\xFF".dup.force_encoding('UTF-8'), nil],
    'a non-String ChatGPT id' => ['openai/session', 42, nil],
    'a Codex uuid' => ['sessionId', '019A4F2E-1C3D-7B8A-9E0F-CAFECAFECAFE',
                       'sessionId:019a4f2e-1c3d-7b8a-9e0f-cafecafecafe'],
    'a Codex id with invalid UTF-8 bytes' => ['sessionId', "\xFF".dup.force_encoding('UTF-8'), nil]
  }.each do |name, (key, value, expected)|
    it "reads #{name}" do
      row = key == 'sessionId' ? codex : chatgpt

      expect(described_class.read(row, { key => value })).to eq(expected)
    end
  end
end
