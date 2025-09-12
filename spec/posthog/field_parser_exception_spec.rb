# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe FieldParser do
    let(:exception) do
      begin
        raise ArgumentError, "Test error message"
      rescue ArgumentError => e
        e
      end
    end

    describe '.parse_for_exception' do
      it 'parses exception with all required fields' do
        fields = {
          distinct_id: 'user_123',
          exception: exception,
          timestamp: Time.parse('1990-07-16 13:30:00.123 UTC')
        }

        result = FieldParser.parse_for_exception(fields)

        expect(result).to be_a(Hash)
        expect(result[:type]).to eq('capture')
        expect(result[:event]).to eq('$exception')
        expect(result[:distinct_id]).to eq('user_123')
        expect(result[:properties]).to have_key('$exception_list')
        expect(result[:properties]['$exception_list']).to be_an(Array)
        expect(result[:properties]['$exception_list'].length).to eq(1)
      end

      it 'includes exception fingerprint when generated' do
        fields = {
          distinct_id: 'user_123',
          exception: exception
        }

        result = FieldParser.parse_for_exception(fields)

        expect(result[:properties]).to have_key('$exception_fingerprint')
        expect(result[:properties]['$exception_fingerprint']).to be_a(String)
      end

      it 'uses custom exception fingerprint when provided' do
        custom_fingerprint = 'custom_error_group_456'
        fields = {
          distinct_id: 'user_123',
          exception: exception,
          exception_fingerprint: custom_fingerprint
        }

        result = FieldParser.parse_for_exception(fields)

        expect(result[:properties]['$exception_fingerprint']).to eq(custom_fingerprint)
      end

      it 'includes tags in properties' do
        tags = { component: 'payment', severity: 'high' }
        fields = {
          distinct_id: 'user_123',
          exception: exception,
          tags: tags
        }

        result = FieldParser.parse_for_exception(fields)

        expect(result[:properties][:component]).to eq('payment')
        expect(result[:properties][:severity]).to eq('high')
      end

      it 'includes extra context in properties' do
        extra = { user_type: 'premium', retry_count: 3 }
        fields = {
          distinct_id: 'user_123',
          exception: exception,
          extra: extra
        }

        result = FieldParser.parse_for_exception(fields)

        expect(result[:properties][:user_type]).to eq('premium')
        expect(result[:properties][:retry_count]).to eq(3)
      end

      it 'handles pre-formatted exception hashes' do
        exception_hash = {
          type: 'CustomError',
          value: 'Custom error message',
          mechanism: { handled: false, synthetic: true, type: 'middleware' },
          stacktrace: { frames: [], type: 'resolved' }
        }

        fields = {
          distinct_id: 'user_123',
          exception: exception_hash,
          exception_fingerprint: 'custom_fingerprint'
        }

        result = FieldParser.parse_for_exception(fields)

        expect(result[:properties]['$exception_list'].first).to eq(exception_hash)
        expect(result[:properties]['$exception_fingerprint']).to eq('custom_fingerprint')
      end

      it 'includes common PostHog properties' do
        fields = {
          distinct_id: 'user_123',
          exception: exception
        }

        result = FieldParser.parse_for_exception(fields)

        expect(result).to have_key(:library)
        expect(result).to have_key(:library_version)
        expect(result).to have_key(:timestamp)
        expect(result[:properties]).to have_key('$lib')
        expect(result[:properties]).to have_key('$lib_version')
        expect(result[:properties]['$lib']).to eq('posthog-ruby')
      end

      it 'handles Date and Time objects in extra context' do
        extra = {
          occurred_at: Time.parse('2023-01-01 12:00:00 UTC'),
          scheduled_date: Date.parse('2023-01-02')
        }

        fields = {
          distinct_id: 'user_123',
          exception: exception,
          extra: extra
        }

        result = FieldParser.parse_for_exception(fields)

        # Should be converted to ISO8601 format
        expect(result[:properties][:occurred_at]).to match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
        expect(result[:properties][:scheduled_date]).to match(/^\d{4}-\d{2}-\d{2}/)
      end

      it 'raises error when exception is missing' do
        fields = { distinct_id: 'user_123' }

        expect { FieldParser.parse_for_exception(fields) }.to raise_error(
          ArgumentError, 'exception must be given'
        )
      end

      it 'raises error when distinct_id is missing' do
        fields = { exception: exception }

        expect { FieldParser.parse_for_exception(fields) }.to raise_error(
          ArgumentError, 'distinct_id must be given'
        )
      end

      it 'raises error when tags is not a hash' do
        fields = {
          distinct_id: 'user_123',
          exception: exception,
          tags: 'invalid'
        }

        expect { FieldParser.parse_for_exception(fields) }.to raise_error(
          ArgumentError, 'tags must be a Hash'
        )
      end

      it 'raises error when extra is not a hash' do
        fields = {
          distinct_id: 'user_123',
          exception: exception,
          extra: ['invalid']
        }

        expect { FieldParser.parse_for_exception(fields) }.to raise_error(
          ArgumentError, 'extra must be a Hash'
        )
      end

      it 'handles empty tags and extra gracefully' do
        fields = {
          distinct_id: 'user_123',
          exception: exception,
          tags: {},
          extra: {}
        }

        result = FieldParser.parse_for_exception(fields)

        expect(result[:properties]).to have_key('$exception_list')
        expect(result[:properties]).to have_key('$exception_fingerprint')
      end

      it 'preserves message_id when provided' do
        message_id = 'custom_message_id_123'
        fields = {
          distinct_id: 'user_123',
          exception: exception,
          message_id: message_id
        }

        result = FieldParser.parse_for_exception(fields)

        expect(result[:messageId]).to eq(message_id)
      end
    end
  end
end