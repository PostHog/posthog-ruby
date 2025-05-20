# frozen_string_literal: true

require 'spec_helper'

class PostHog
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
end
