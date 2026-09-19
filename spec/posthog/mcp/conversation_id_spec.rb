# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::ConversationId do
  let(:handle) { '019fd2b0-1111-7111-8111-111111111111' }

  describe '.resolve' do
    it 'echoes a minted-shaped handle (lowercased) and mints over anything else' do
      expect(described_class.resolve(true, { conversation_id: handle }, 'a_tool',
                                     'get_more_tools')).to eq([handle, false])
      expect(described_class.resolve(true, { 'conversation_id' => handle.upcase }, 'a_tool', 'get_more_tools'))
        .to eq([handle, false])
      %w[conv-1 1 session chat_abc not-a-uuid 019fd2b0-1111-4111-8111-111111111111].each do |value|
        id, minted = described_class.resolve(true, { conversation_id: value }, 'a_tool', 'get_more_tools')
        expect(minted).to be(true)
        expect(id).not_to eq(value)
        expect(id).to match(described_class::MINTED_CONVERSATION_ID)
      end
      minted_id, = described_class.resolve(true, {}, 'a_tool', 'get_more_tools')
      expect(described_class.resolve(true, { conversation_id: minted_id }, 'a_tool',
                                     'get_more_tools')).to eq([minted_id, false])
    end

    it 'is inert when disabled or for the missing-capability tool' do
      expect(described_class.resolve(false, { conversation_id: handle }, 'a_tool',
                                     'get_more_tools')).to eq([nil, false])
      expect(described_class.resolve(true, {}, 'get_more_tools', 'get_more_tools')).to eq([nil, false])
    end
  end

  describe '.extract' do
    it 'trims and rejects non-strings' do
      expect(described_class.extract('conversation_id' => ' abc ')).to eq('abc')
      expect(described_class.extract(conversation_id: 123)).to be_nil
      expect(described_class.extract(conversation_id: '   ')).to be_nil
      expect(described_class.extract('not a hash')).to be_nil
      expect(described_class.extract(nil)).to be_nil
    end
  end

  describe '.inject_prompt_back' do
    it 'appends a compact JSON text block when content is an array, including errored results' do
      result = described_class.inject_prompt_back({ content: [{ type: 'text', text: 'hello' }] }, 'conv-123')
      expect(result[:content].length).to eq(2)
      expect(result[:content][1]).to eq(type: 'text', text: '{"conversation_id":"conv-123"}')
      errored = described_class.inject_prompt_back({ isError: true, content: [{ type: 'text', text: 'oops' }] },
                                                   'conv-123')
      expect(errored[:content][1][:text]).to include('conv-123')
      expect(described_class.inject_prompt_back({}, 'conv-123')).to eq({})
      expect(described_class.inject_prompt_back({ content: 'not-an-array' }, 'conv-123')).to eq(content: 'not-an-array')
      expect(described_class.inject_prompt_back(nil, 'conv-123')).to be_nil
      expect(described_class.inject_prompt_back('string', 'conv-123')).to eq('string')
    end
  end

  describe '.mirror_instructions' do
    it 'writes into structuredContent only when present and customer data wins' do
      result, delivered = described_class.mirror_instructions({ content: [], structuredContent: { total: 7 } },
                                                              'conv-9')
      expect(delivered).to be(true)
      expect(result[:structuredContent]).to eq(total: 7, _mcp_instructions: { 'conversation_id' => 'conv-9' })

      untouched = { content: [], structuredContent: { _mcp_instructions: { 'x' => 1 } } }
      expect(described_class.mirror_instructions(untouched, 'conv-9')).to eq([untouched, false])
      expect(described_class.mirror_instructions({ content: [] }, 'conv-9')).to eq([{ content: [] }, false])
      expect(described_class.mirror_instructions('nope', 'conv-9')).to eq(['nope', false])
    end
  end
end
