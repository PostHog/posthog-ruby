# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe MessageBatch do
    subject { described_class.new(100) }

    describe '#<<' do
      it 'appends messages' do
        subject << { 'a' => 'b' }
        expect(subject.length).to eq(1)
        expect(JSON.parse(subject.to_json)).to eq([{ 'a' => 'b' }])
      end

      [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |number|
        it "serializes #{number} as null without changing the input or losing neighboring messages" do
          message = { properties: { number: number, items: [1, { number: number }, number, 3] } }
          subject << message
          subject << { event: 'neighbor', properties: { finite: 2.5 } }

          expect(JSON.parse(JSON.generate(api_key: 'test', batch: subject))).to eq(
            'api_key' => 'test',
            'batch' => [
              { 'properties' => { 'number' => nil, 'items' => [1, { 'number' => nil }, nil, 3] } },
              { 'event' => 'neighbor', 'properties' => { 'finite' => 2.5 } }
            ]
          )
          expect(message[:properties][:number]).to equal(number)
          expect(message[:properties][:items][1][:number]).to equal(number)
          expect(message[:properties][:items][2]).to equal(number)
        end
      end

      it 'still reports unsupported serialization errors without dropping valid neighbors' do
        unsupported = Object.new
        def unsupported.as_json(*)
          raise TypeError, 'unsupported value'
        end

        def unsupported.to_json(*)
          raise TypeError, 'unsupported value'
        end
        subject << { event: 'neighbor' }

        expect { subject << { properties: { number: Float::NAN, unsupported: unsupported } } }
          .to raise_error(MessageBatch::JSONGenerationError, /unsupported value/)
        expect(JSON.parse(subject.to_json)).to eq([{ 'event' => 'neighbor' }])
      end

      it 'rejects messages that exceed the maximum allowed size' do
        max_bytes = Defaults::Message::MAX_BYTES
        message = { 'a' => 'b' * max_bytes }

        subject << message
        expect(subject.length).to eq(0)
      end
    end

    describe '#clear' do
      it 'resets both the messages and the accumulated byte size' do
        stub_const('PostHog::Defaults::Message::MAX_BYTES', 20)
        stub_const('PostHog::Defaults::MessageBatch::MAX_BYTES', 40)
        3.times { subject << { a: 'b' } }
        expect(subject).to be_full

        subject.clear

        expect(subject).to be_empty
        expect(subject.length).to eq(0)
        expect(JSON.parse(subject.to_json)).to eq([])
        subject << { c: 'd' }
        expect(subject).not_to be_full
        expect(JSON.parse(subject.to_json)).to eq([{ 'c' => 'd' }])
      end
    end

    describe '#full?' do
      it 'returns true once item count is exceeded' do
        99.times { subject << { a: 'b' } }
        expect(subject.full?).to be(false)

        subject << { a: 'b' }
        expect(subject.full?).to be(true)
      end

      it 'returns true once max size is almost exceeded' do
        message = { a: 'b' * (Defaults::Message::MAX_BYTES - 10) }

        message_size = message.to_json.bytesize

        # Each message is under the individual limit
        expect(message_size).to be < Defaults::Message::MAX_BYTES

        # Size of the batch is over the limit
        expect(50 * message_size).to be > Defaults::MessageBatch::MAX_BYTES

        expect(subject.full?).to be(false)
        50.times { subject << message }
        expect(subject.full?).to be(true)
      end
    end
  end
end
