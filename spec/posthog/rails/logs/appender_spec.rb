# frozen_string_literal: true

require 'spec_helper'

$LOAD_PATH.unshift File.expand_path('../../../../posthog-rails/lib', __dir__)

require 'posthog/rails/logs/appender'
require 'posthog/rails/logs/rate_limiter'

RSpec.describe PostHog::Rails::Logs::Appender do
  let(:context_class) { PostHog.const_get(:Internal).const_get(:Context) }

  # Records every on_emit call so we can assert the emitted payload.
  let(:otel_logger) do
    Class.new do
      attr_reader :emitted

      def initialize
        @emitted = []
      end

      def on_emit(**kwargs)
        @emitted << kwargs
      end
    end.new
  end

  subject(:appender) { described_class.new(otel_logger, level: Logger::INFO) }

  describe '#add' do
    it 'emits a record with body and mapped severity' do
      appender.info('hello world')

      expect(otel_logger.emitted.size).to eq(1)
      record = otel_logger.emitted.first
      expect(record[:body]).to eq('hello world')
      expect(record[:severity_number]).to eq(9)
      expect(record[:severity_text]).to eq('INFO')
    end

    # Covers every entry in Severity::MAPPING so a regression in any level
    # (including the UNKNOWN -> INFO fallback) is caught.
    {
      debug: [5, 'DEBUG'],
      info: [9, 'INFO'],
      warn: [13, 'WARN'],
      error: [17, 'ERROR'],
      fatal: [21, 'FATAL'],
      unknown: [9, 'INFO']
    }.each do |level_method, (number, text)|
      it "maps #{level_method} to severity #{number} (#{text})" do
        # Use a DEBUG-level appender so even debug records are emitted.
        described_class.new(otel_logger, level: Logger::DEBUG).public_send(level_method, 'msg')

        record = otel_logger.emitted.first
        expect(record[:severity_number]).to eq(number)
        expect(record[:severity_text]).to eq(text)
      end
    end

    it 'drops messages below the configured level' do
      appender.debug('too quiet')

      expect(otel_logger.emitted).to be_empty
    end

    it 'resolves block-form messages' do
      appender.info { 'lazy message' }

      expect(otel_logger.emitted.first[:body]).to eq('lazy message')
    end

    it 'inspects non-string messages' do
      appender.info(%w[a b])

      expect(otel_logger.emitted.first[:body]).to eq('["a", "b"]')
    end

    it 'suppresses self-logs carrying the posthog-ruby prefix' do
      appender.info('[posthog-ruby] internal diagnostic')

      expect(otel_logger.emitted).to be_empty
    end

    it 'does not suppress app logs that merely mention the SDK mid-string' do
      appender.info('upstream failed: [posthog-ruby] timeout')

      expect(otel_logger.emitted.size).to eq(1)
    end

    it 'suppresses logs emitted under the PostHog progname' do
      appender.info('PostHog') { 'internal diagnostic' }

      expect(otel_logger.emitted).to be_empty
    end

    it 'never raises even if the otel logger blows up' do
      allow(otel_logger).to receive(:on_emit).and_raise(StandardError, 'export failed')

      expect { appender.info('hello') }.not_to raise_error
      expect(appender.info('hello')).to be(true)
    end
  end

  describe 'rate limiting' do
    let(:rate_limiter) { PostHog::Rails::Logs::RateLimiter.new(2) }

    subject(:appender) { described_class.new(otel_logger, level: Logger::INFO, rate_limiter: rate_limiter) }

    it 'forwards records while under the cap' do
      2.times { appender.info('fine') }

      expect(otel_logger.emitted.size).to eq(2)
    end

    it 'emits a single cap notice, then drops silently for the rest of the window' do
      5.times { |i| appender.info("msg #{i}") }

      expect(otel_logger.emitted.size).to eq(3)
      notice = otel_logger.emitted.last
      expect(notice[:body]).to include('rate cap reached (2 records/minute)')
      expect(notice[:severity_text]).to eq('WARN')
    end

    it 'does not count records filtered by level or self-log suppression' do
      appender.debug('below level')
      appender.info('[posthog-ruby] internal diagnostic')
      2.times { appender.info('fine') }

      expect(otel_logger.emitted.size).to eq(2)
      expect(otel_logger.emitted.map { |r| r[:body] }).to all(eq('fine'))
    end
  end

  describe 'context correlation' do
    it 'stamps the request distinct_id, session_id, and request metadata' do
      context_class.with_context(
        distinct_id: 'user-42',
        session_id: 'session-99',
        properties: { '$current_url' => 'https://example.com/widgets', '$request_method' => 'GET' }
      ) do
        appender.info('within request')
      end

      attributes = otel_logger.emitted.first[:attributes]
      expect(attributes['posthogDistinctId']).to eq('user-42')
      expect(attributes['sessionId']).to eq('session-99')
      expect(attributes['$current_url']).to eq('https://example.com/widgets')
      expect(attributes['$request_method']).to eq('GET')
    end

    it 'omits correlation attributes when there is no active context' do
      appender.info('no context')

      attributes = otel_logger.emitted.first[:attributes]
      expect(attributes).not_to have_key('posthogDistinctId')
      expect(attributes).not_to have_key('sessionId')
    end
  end
end
