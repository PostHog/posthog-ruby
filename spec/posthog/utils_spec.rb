# frozen_string_literal: true

require 'spec_helper'
require 'open3'

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

    it 'size limited array drops oldest entries without exposing the constant publicly' do
      expect { PostHog::Utils::SizeLimitedArray }.to raise_error(NameError)

      array_class = PostHog::Utils.const_get(:SizeLimitedArray, false)
      array = array_class.new(3)

      (1..5).each { |i| array << i }

      expect(array).to eq([3, 4, 5])
    end
  end

  describe '.datetime_in_iso8601' do
    it 'converts a DateTime with an offset to UTC with 3 truncated fractional digits' do
      value = DateTime.new(2026, 11, 23, 10, 30, 15.123999r, '+05:30')

      expect(PostHog::Utils.datetime_in_iso8601(value)).to eq('2026-11-23T05:00:15.123Z')
    end

    it 'converts a Time with an offset to UTC' do
      value = Time.new(2026, 11, 23, 10, 30, 15.123456r, '+05:30')

      expect(PostHog::Utils.datetime_in_iso8601(value)).to eq('2026-11-23T05:00:15.123Z')
    end

    it 'converts a TimeWithZone to UTC' do
      value = Time.new(2026, 11, 23, 10, 30, 15.123456r, '+05:30').in_time_zone('Asia/Kolkata')

      expect(PostHog::Utils.datetime_in_iso8601(value)).to eq('2026-11-23T05:00:15.123Z')
    end

    it 'writes UTC DateTime and Time values with Z' do
      expect(PostHog::Utils.datetime_in_iso8601(DateTime.new(2013, 1, 1))).to eq('2013-01-01T00:00:00.000Z')
      expect(PostHog::Utils.datetime_in_iso8601(Time.utc(2013))).to eq('2013-01-01T00:00:00.000Z')
    end

    it 'keeps a Date as a calendar date' do
      expect(PostHog::Utils.datetime_in_iso8601(Date.new(2026, 11, 23))).to eq('2026-11-23')
    end

    {
      'plain Ruby' => '',
      'ActiveSupport' => "require 'active_support/all'\n"
    }.each do |label, preamble|
      it "writes the same UTC string under #{label} regardless of the process TZ" do
        script = <<~RUBY
          require 'date'
          #{preamble}require 'posthog'
          values = [
            DateTime.new(2026, 11, 23, 10, 30, 15.123456r, '+05:30'),
            Time.new(2026, 11, 23, 10, 30, 15.123456r, '+05:30')
          ]
          puts values.map { |value| PostHog::Utils.datetime_in_iso8601(value) }.join(',')
        RUBY

        %w[UTC America/New_York Asia/Tokyo].each do |tz|
          stdout, stderr, status = Open3.capture3({ 'TZ' => tz }, RbConfig.ruby, '-Ilib', '-e', script)

          expect(status).to be_success, stderr
          expect(stderr).not_to include('DEPRECATION WARNING')
          expect(stdout.strip).to eq('2026-11-23T05:00:15.123Z,2026-11-23T05:00:15.123Z')
        end
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
