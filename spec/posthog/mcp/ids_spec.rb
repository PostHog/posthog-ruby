# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Ids do
  describe '.deterministic_prefixed_id' do
    # Frozen cross-SDK vectors from posthog-python test_conversation_session.py.
    it 'matches the TypeScript and Python SDKs byte for byte' do
      expect(described_class.deterministic_prefixed_id('ses', 'conv-123')).to eq('ses_19c018eaeb9263330c016d3a3a41474b')
      expect(described_class.deterministic_prefixed_id('ses', '0198d3a7-1111-7222-8333-444455556666'))
        .to eq('ses_57a5f3768678e803a4af9566ca8a661b')
      expect(described_class.deterministic_prefixed_id('ses', 'a')).to eq('ses_8601ec8c0eec655f4ec03fd0b1129ba7')
    end

    it 'is stable and distinguishes inputs' do
      a = described_class.deterministic_prefixed_id('ses', 'mcp-session:project')
      expect(a).to eq(described_class.deterministic_prefixed_id('ses', 'mcp-session:project'))
      expect(a).not_to eq(described_class.deterministic_prefixed_id('ses', 'other-session:project'))
      expect(a).to match(/\Ases_[0-9a-f]{32}\z/)
    end
  end

  describe '.uuid_v7' do
    it 'produces version 7, variant 10 uuids' do
      uuid = described_class.uuid_v7
      expect(uuid).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end

    it 'is time-ordered and unique' do
      first = Array.new(25) { described_class.uuid_v7 }
      sleep 0.005
      second = Array.new(25) { described_class.uuid_v7 }
      expect((first + second).uniq.length).to eq(50)
      expect(first.max).to be < second.min
    end
  end

  describe '.new_prefixed_id' do
    it 'prefixes a uuidv7' do
      expect(described_class.new_prefixed_id('evt')).to match(/\Aevt_[0-9a-f-]{36}\z/)
      expect(described_class.new_prefixed_id('ses')).to match(/\Ases_[0-9a-f-]{36}\z/)
    end
  end
end
