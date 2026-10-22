# frozen_string_literal: true

RSpec.shared_examples 'message_batch_json' do
  [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |number|
    it "MessageBatch serializes #{number} as null" do
      batch = PostHog::MessageBatch.new(100)
      message = { 'event' => 'non-finite',
                  'properties' => { 'number' => number, 'items' => [1, number, { 'number' => number }] } }
      batch << message
      batch << { 'event' => 'neighbor', 'properties' => { 'finite' => 2.5, 'literal' => 'NaN' } }

      expect(JSON.parse(JSON.generate(batch))).to eq([
                                                       { 'event' => 'non-finite',
                                                         'properties' => { 'number' => nil,
                                                                           'items' => [1, nil, { 'number' => nil }] } },
                                                       { 'event' => 'neighbor',
                                                         'properties' => { 'finite' => 2.5, 'literal' => 'NaN' } }
                                                     ])
      expect(message['properties']['number']).to equal(number)
      expect(message['properties']['items'][1]).to equal(number)
      expect(message['properties']['items'][2]['number']).to equal(number)
    end
  end

  it 'MessageBatch generates proper JSON' do
    batch = PostHog::MessageBatch.new(100)
    batch << { 'a' => 'b' }
    batch << { 'c' => 'd' }

    expect(JSON.generate(batch)).to eq('[{"a":"b"},{"c":"d"}]')
  end
end
