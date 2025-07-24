# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe Utils do
    it 'size limited dict works' do
      size = 10
      dict = PostHog::Utils::SizeLimitedHash.new(size)
      (0..100).each do |i|
        dict[i] = i

        expect(dict[i]).to eq(i)
        expect(dict.length).to eq((i % size) + 1)

        next unless i % size == 0

        # old numbers should've been removed
        expect(dict[i - 1]).to be_nil
        expect(dict[i - 3]).to be_nil
        expect(dict[i - 5]).to be_nil
        expect(dict[i - 9]).to be_nil
      end
    end

    it 'size limited dict works with default block generator' do
      size = 10
      dict = PostHog::Utils::SizeLimitedHash.new(size) { |hash, key| hash[key] = [] }
      (0..100).each do |i|
        dict[i] << i

        expect(dict[i]).to eq([i])
        expect(dict.length <= size).to eq(true)
      end
    end
  end

  describe '.get_by_symbol_or_string_key' do
    it 'returns value for symbol key when present' do
      hash = { test_key: 'symbol_value', 'test_key' => 'string_value' }
      expect(PostHog::Utils.get_by_symbol_or_string_key(hash, :test_key)).to eq('symbol_value')
    end

    it 'returns value for string key when symbol key not present' do
      hash = { 'test_key' => 'string_value' }
      expect(PostHog::Utils.get_by_symbol_or_string_key(hash, :test_key)).to eq('string_value')
    end

    it 'handles falsy values correctly' do
      hash = { test_key: false, 'test_key' => 'fallback' }
      expect(PostHog::Utils.get_by_symbol_or_string_key(hash, :test_key)).to eq(false)
    end

    it 'handles nil values correctly' do
      hash = { test_key: nil, 'test_key' => 'fallback' }
      expect(PostHog::Utils.get_by_symbol_or_string_key(hash, :test_key)).to be_nil
    end

    it 'returns nil when neither key is present' do
      hash = { other_key: 'value' }
      expect(PostHog::Utils.get_by_symbol_or_string_key(hash, :test_key)).to be_nil
    end

    it 'works with string key parameter' do
      hash = { test_key: 'symbol_value' }
      expect(PostHog::Utils.get_by_symbol_or_string_key(hash, 'test_key')).to eq('symbol_value')
    end
  end
end
