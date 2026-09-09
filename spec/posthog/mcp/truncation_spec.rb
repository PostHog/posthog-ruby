# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Truncation do
  describe '.normalize' do
    it 'caps strings at 32KB with a ... suffix' do
      out = described_class.normalize('a' * 33_000)
      expect(out.length).to eq(32_771)
      expect(out).to end_with('...')
      expect(described_class.normalize('a' * 32_768)).to eq('a' * 32_768)
    end

    it 'collapses depth and breadth with the shared markers' do
      nested = (1..15).reduce({}) { |acc, _| { 'nested' => acc } }
      expect(described_class.normalize(nested, 5).dig('nested', 'nested', 'nested', 'nested',
                                                      'nested')).to eq('[Object]')
      deep_array = (1..15).reduce([]) { |acc, _| [acc] }
      expect(described_class.normalize(deep_array, 3)[0][0][0]).to eq('[Array]')
      expect(described_class.normalize({ 'a' => 1 }, 0)).to eq('[Object]')
      expect(described_class.normalize([1, 2], 0)).to eq('[Array]')
      expect(described_class.normalize('hello', 0)).to eq('hello')

      wide = (0...150).to_h { |i| ["key#{i}", i] }
      out = described_class.normalize(wide, 10, 5)
      expect(out.length).to eq(6)
      expect(out['...']).to eq('[MaxProperties ~]')
      out = described_class.normalize((0...150).to_a, 10, 5)
      expect(out.length).to eq(6)
      expect(out.last).to eq('[MaxProperties ~]')
    end

    it 'marks cycles and coerces scalars' do
      obj = { 'a' => 1 }
      obj['self'] = obj
      expect(described_class.normalize(obj)).to eq('a' => 1, 'self' => '[Circular ~]')
      arr = [1, 2]
      arr << arr
      expect(described_class.normalize(arr)).to eq([1, 2, '[Circular ~]'])
      shared = { 'x' => 1 }
      expect(described_class.normalize('a' => shared, 'b' => shared)).to eq('a' => { 'x' => 1 }, 'b' => { 'x' => 1 })
      expect(described_class.normalize(Float::NAN)).to eq('[NaN]')
      expect(described_class.normalize(Float::INFINITY)).to eq('[Infinity]')
      expect(described_class.normalize(-Float::INFINITY)).to eq('[-Infinity]')
      expect(described_class.normalize(true)).to eq(true)
      expect(described_class.normalize(7)).to eq(7)
      expect(described_class.normalize(Time.utc(2025, 1, 15, 12))).to eq('2025-01-15T12:00:00.000Z')
      expect(described_class.normalize(:sym)).to eq('sym')
      expect(described_class.normalize(-> {})).to start_with('[Function:')
    end
  end

  describe '.truncate_event' do
    it 'applies field caps' do
      event = described_class.truncate_event(
        'user_intent' => 'x' * 3000, 'resource_name' => 't' * 300, 'server_name' => 's' * 300,
        'client_version' => 'cv' * 200,
        'error' => { '$exception_list' => [{ 'value' => 'e' * 3000,
                                             'stacktrace' => { 'frames' => (0...80).map do |i|
                                               { 'filename' => "file#{i}.rb" }
                                             end } }] }
      )
      expect(event['user_intent'].length).to eq(2051)
      expect(event['resource_name'].length).to eq(259)
      expect(event['server_name'].length).to eq(259)
      expect(event['client_version'].length).to eq(259)
      exception = event['error']['$exception_list'][0]
      expect(exception['value'].length).to eq(2051)
      frames = exception['stacktrace']['frames']
      expect(frames.length).to eq(50)
      expect(frames[0]['filename']).to eq('file0.rb')
      expect(frames[24]['filename']).to eq('file24.rb')
      expect(frames[25]['filename']).to eq('file55.rb')
      expect(frames[49]['filename']).to eq('file79.rb')
    end

    it 'bounds user-supplied properties so the event fits the core client budget' do
      event = described_class.truncate_event('event_type' => 'custom', 'properties' => { 'rows' => (1..10_000).to_a })
      expect(described_class.json_byte_size(event)).to be <= described_class::MAX_EVENT_BYTES
      expect(event['properties']['rows'].length).to be <= described_class::MAX_BREADTH + 1
    end

    it 'caps response text blocks and then fits the whole event in the byte budget' do
      content = described_class.truncate_response_content('content' => [{ 'type' => 'text', 'text' => 'x' * 40_000 },
                                                                        { 'type' => 'text', 'text' => 'short' }])
      expect(content['content'][0]['text'].length).to eq(32_771)
      expect(content['content'][1]['text']).to eq('short')

      event = described_class.truncate_event('response' => content)
      expect(event['response']['content'][0]['text']).to end_with('...')
      expect(described_class.json_byte_size(event)).to be <= described_class::MAX_EVENT_BYTES
    end

    it 'keeps events within the byte budget without mutating the input' do
      timestamp = Time.utc(2025, 1, 15, 12)
      cases = [
        { 'parameters' => { 'a' => 'x' * 60_000, 'b' => 'x' * 60_000, 'c' => 'x' * 60_000, 'd' => 'x' * 60_000 } },
        { 'parameters' => (1..8).reduce('leaf' => 'x' * 15_000) do |acc, _|
          { 'level' => acc, 'pad' => 'x' * 15_000 }
        end },
        { 'parameters' => 'x' * 120_000 },
        { 'parameters' => (0...60).to_h { |i| ["field_#{i}", 'z' * 5000] } },
        { 'parameters' => { 'blob' => 'z' * 300_000 } }
      ]
      cases.each do |input|
        event = input.merge('timestamp' => timestamp, 'event_type' => 'mcp:tools/call', 'is_error' => false)
        before = Marshal.load(Marshal.dump(event))
        expect(described_class.json_byte_size(event)).to be > described_class::MAX_EVENT_BYTES
        out = described_class.truncate_event(event)
        expect(described_class.json_byte_size(out)).to be <= described_class::MAX_EVENT_BYTES
        expect(out['timestamp']).to eq(timestamp)
        expect(out['event_type']).to eq('mcp:tools/call')
        expect(event).to eq(before)
      end
    end

    it 'leaves SDK-controlled fields untouched' do
      event = { 'event_type' => 'mcp:tools/call', 'resource_name' => 'echo', 'is_error' => false, 'duration' => 342 }
      expect(described_class.truncate_event(event)).to eq(event)
    end
  end
end
