# frozen_string_literal: true

require 'spec_helper'
require 'posthog/feature_flag_result'

module PostHog
  describe FeatureFlagResult do
    describe '#initialize' do
      it 'initializes with all attributes' do
        result = FeatureFlagResult.new(
          key: 'test-flag',
          enabled: true,
          variant: 'control',
          payload: { 'foo' => 'bar' }
        )

        expect(result.key).to eq('test-flag')
        expect(result.enabled?).to be true
        expect(result.variant).to eq('control')
        expect(result.payload).to eq({ 'foo' => 'bar' })
      end

      it 'initializes with minimal attributes' do
        result = FeatureFlagResult.new(key: 'test-flag', enabled: false)

        expect(result.key).to eq('test-flag')
        expect(result.enabled?).to be false
        expect(result.variant).to be_nil
        expect(result.payload).to be_nil
      end
    end

    describe '#value' do
      it 'returns variant when present' do
        result = FeatureFlagResult.new(key: 'test-flag', enabled: true, variant: 'control')

        expect(result.value).to eq('control')
      end

      it 'returns enabled when variant is not present' do
        result = FeatureFlagResult.new(key: 'test-flag', enabled: true)

        expect(result.value).to be true
      end

      it 'returns false when flag is disabled and no variant' do
        result = FeatureFlagResult.new(key: 'test-flag', enabled: false)

        expect(result.value).to be false
      end
    end

    describe '.from_value_and_payload' do
      context 'with nil value' do
        it 'returns nil' do
          result = FeatureFlagResult.from_value_and_payload('test-flag', nil, nil)

          expect(result).to be_nil
        end
      end

      context 'with boolean true value' do
        it 'creates result with enabled true and no variant' do
          result = FeatureFlagResult.from_value_and_payload('test-flag', true, nil)

          expect(result.key).to eq('test-flag')
          expect(result.enabled?).to be true
          expect(result.variant).to be_nil
          expect(result.payload).to be_nil
        end
      end

      context 'with boolean false value' do
        it 'creates result with enabled false and no variant' do
          result = FeatureFlagResult.from_value_and_payload('test-flag', false, nil)

          expect(result.key).to eq('test-flag')
          expect(result.enabled?).to be false
          expect(result.variant).to be_nil
          expect(result.payload).to be_nil
        end
      end

      context 'with string variant' do
        it 'creates result with enabled true and variant set' do
          result = FeatureFlagResult.from_value_and_payload('test-flag', 'control', nil)

          expect(result.key).to eq('test-flag')
          expect(result.enabled?).to be true
          expect(result.variant).to eq('control')
          expect(result.payload).to be_nil
        end
      end

      context 'with JSON string payload' do
        it 'parses the JSON payload' do
          result = FeatureFlagResult.from_value_and_payload('test-flag', true, '{"foo": "bar"}')

          expect(result.payload).to eq({ 'foo' => 'bar' })
        end

        it 'parses complex nested JSON payload' do
          json_payload = '{"settings": {"theme": "dark", "notifications": true}, "features": ["a", "b"]}'
          result = FeatureFlagResult.from_value_and_payload('test-flag', true, json_payload)

          expect(result.payload).to eq({
                                         'settings' => { 'theme' => 'dark', 'notifications' => true },
                                         'features' => %w[a b]
                                       })
        end
      end

      context 'with non-JSON string payload' do
        it 'returns the string as-is' do
          result = FeatureFlagResult.from_value_and_payload('test-flag', true, 'just a plain string')

          expect(result.payload).to eq('just a plain string')
        end
      end

      context 'with empty string payload' do
        it 'returns nil' do
          result = FeatureFlagResult.from_value_and_payload('test-flag', true, '')

          expect(result.payload).to be_nil
        end
      end

      context 'with hash payload' do
        it 'passes through hash payloads unchanged' do
          hash_payload = { 'foo' => 'bar' }
          result = FeatureFlagResult.from_value_and_payload('test-flag', true, hash_payload)

          expect(result.payload).to eq({ 'foo' => 'bar' })
        end
      end

      context 'with nil payload' do
        it 'sets payload to nil' do
          result = FeatureFlagResult.from_value_and_payload('test-flag', true, nil)

          expect(result.payload).to be_nil
        end
      end

      context 'with variant and payload' do
        it 'creates result with variant and parsed payload' do
          result = FeatureFlagResult.from_value_and_payload('test-flag', 'control', '{"discount": 10}')

          expect(result.key).to eq('test-flag')
          expect(result.enabled?).to be true
          expect(result.variant).to eq('control')
          expect(result.payload).to eq({ 'discount' => 10 })
          expect(result.value).to eq('control')
        end
      end
    end
  end
end
