# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe BackoffPolicy do
    describe '#initialize' do
      context 'no options are given' do
        it 'sets default min_timeout_ms' do
          actual = subject.instance_variable_get(:@min_timeout_ms)
          expect(actual).to eq(described_class::MIN_TIMEOUT_MS)
        end

        it 'sets default max_timeout_ms' do
          actual = subject.instance_variable_get(:@max_timeout_ms)
          expect(actual).to eq(described_class::MAX_TIMEOUT_MS)
        end

        it 'sets default multiplier' do
          actual = subject.instance_variable_get(:@multiplier)
          expect(actual).to eq(described_class::MULTIPLIER)
        end

        it 'sets default randomization factor' do
          actual = subject.instance_variable_get(:@randomization_factor)
          expect(actual).to eq(described_class::RANDOMIZATION_FACTOR)
        end
      end

      context 'options are given' do
        let(:min_timeout_ms) { 1234 }
        let(:max_timeout_ms) { 5678 }
        let(:multiplier) { 24 }
        let(:randomization_factor) { 0.4 }

        let(:options) do
          {
            min_timeout_ms: min_timeout_ms,
            max_timeout_ms: max_timeout_ms,
            multiplier: multiplier,
            randomization_factor: randomization_factor
          }
        end

        subject { described_class.new(options) }

        it 'sets passed in min_timeout_ms' do
          actual = subject.instance_variable_get(:@min_timeout_ms)
          expect(actual).to eq(min_timeout_ms)
        end

        it 'sets passed in max_timeout_ms' do
          actual = subject.instance_variable_get(:@max_timeout_ms)
          expect(actual).to eq(max_timeout_ms)
        end

        it 'sets passed in multiplier' do
          actual = subject.instance_variable_get(:@multiplier)
          expect(actual).to eq(multiplier)
        end

        it 'sets passed in randomization_factor' do
          actual = subject.instance_variable_get(:@randomization_factor)
          expect(actual).to eq(randomization_factor)
        end
      end
    end

    describe '#next_interval' do
      subject do
        described_class.new(
          min_timeout_ms: 1000,
          max_timeout_ms: 10_000,
          multiplier: 2,
          randomization_factor: 0.5
        )
      end

      it 'returns exponentially increasing durations without jitter' do
        allow(subject).to receive(:rand).and_return(0.0)

        expect(Array.new(4) { subject.next_interval }).to eq([1000, 2000, 4000, 8000])
      end

      [
        [0.25, [1000, 1750, 3500, 7000]],
        [0.75, [1375, 2750, 5500, 10_000]]
      ].each do |random, expected|
        it "applies bounded jitter with random value #{random}" do
          allow(subject).to receive(:rand).and_return(random)

          expect(Array.new(4) { subject.next_interval }).to eq(expected)
        end
      end

      it 'caps maximum duration at max_timeout_ms' do
        allow(subject).to receive(:rand).and_return(0.0)
        4.times { subject.next_interval }

        expect(subject.next_interval).to eq(10_000)
        expect(subject.next_interval).to eq(10_000)
      end
    end
  end
end
