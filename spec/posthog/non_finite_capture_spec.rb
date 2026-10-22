# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Capture with non-finite event properties' do
  [true, false].each do |sync_mode|
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |number|
      it "delivers #{number} as null with sync_mode: #{sync_mode}" do
        payloads = []
        errors = []
        request = stub_request(:post, 'https://us.i.posthog.com/batch/').to_return do |req|
          payloads << JSON.parse(req.body)
          { status: 200, body: '{}' }
        end
        client = PostHog::Client.new(
          api_key: API_KEY, sync_mode: sync_mode, batch_size: 2, flush_interval_seconds: 60,
          compress_request: false, on_error: proc { |*error| errors << error }
        )
        nested = { 'number' => number, 'finite' => 1.25 }.freeze
        items = [0, number, { 'number' => number }.freeze, [number].freeze, false, nil].freeze
        properties = {
          'number' => number, 'nested' => nested, 'items' => items,
          'finite' => 42, 'enabled' => false, 'null' => nil,
          'literals' => %w[NaN Infinity -Infinity], 'date' => Date.new(2026, 10, 22)
        }

        expect(client.capture(distinct_id: 'user', event: 'non-finite', properties: properties)).to eq(true)
        expect(client.capture(distinct_id: 'user', event: 'neighbor', properties: { 'valid' => true })).to eq(true)
        expect(client.flush(timeout: 2)).to eq(true)

        events = payloads.flat_map { |payload| payload.fetch('batch') }
        expect(events.map { |event| event.fetch('event') }).to eq(%w[non-finite neighbor])
        expect(events.first.fetch('properties')).to include(
          'number' => nil, 'nested' => { 'number' => nil, 'finite' => 1.25 },
          'items' => [0, nil, { 'number' => nil }, [nil], false, nil],
          'finite' => 42, 'enabled' => false, 'null' => nil,
          'literals' => %w[NaN Infinity -Infinity], 'date' => '2026-10-22',
          '$lib' => 'posthog-ruby', '$lib_version' => PostHog::VERSION
        )
        expect(events.last.fetch('properties')).to include('valid' => true)
        expect(properties['number']).to equal(number)
        expect(nested['number']).to equal(number)
        expect(items[1]).to equal(number)
        expect(items[2]['number']).to equal(number)
        expect(items[3][0]).to equal(number)
        expect(errors).to eq([])
        expect(request).to have_been_requested.times(sync_mode ? 2 : 1)
      ensure
        client&.shutdown(timeout: 2)
      end
    end
  end
end
