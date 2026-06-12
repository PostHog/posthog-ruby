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

    # Covers every Ruby Logger severity so a regression in any level
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

    it 'stamps the progname as the OTel-conventional logger.name attribute' do
      appender.info('MyJob') { 'job ran' }

      expect(otel_logger.emitted.first[:attributes]['logger.name']).to eq('MyJob')
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

  describe 'before_send' do
    it 'sends the record returned by the callback' do
      before_send = proc { |record| record.merge(body: record[:body].gsub('secret', '[redacted]')) }
      appender = described_class.new(otel_logger, level: Logger::INFO, before_send: before_send)

      appender.info('the secret token')

      expect(otel_logger.emitted.first[:body]).to eq('the [redacted] token')
    end

    it 'exposes the severity as a symbol enum' do
      seen = nil
      before_send = proc do |record|
        seen = record[:severity]
        record
      end
      appender = described_class.new(otel_logger, level: Logger::INFO, before_send: before_send)

      appender.warn('careful')

      expect(seen).to eq(:warn)
    end

    it 'derives the OTel severity pair from a severity changed by the callback' do
      before_send = proc { |record| record.merge(severity: :error) }
      appender = described_class.new(otel_logger, level: Logger::INFO, before_send: before_send)

      appender.info('actually an error')

      record = otel_logger.emitted.first
      expect(record[:severity_number]).to eq(17)
      expect(record[:severity_text]).to eq('ERROR')
    end

    it 'falls back to INFO when the callback sets an unrecognized severity' do
      before_send = proc { |record| record.merge(severity: :loud) }
      appender = described_class.new(otel_logger, level: Logger::INFO, before_send: before_send)

      appender.warn('odd level')

      record = otel_logger.emitted.first
      expect(record[:severity_number]).to eq(9)
      expect(record[:severity_text]).to eq('INFO')
    end

    it 'drops the record when the callback returns nil' do
      before_send = proc { |record| record[:body].include?('secret') ? nil : record }
      appender = described_class.new(otel_logger, level: Logger::INFO, before_send: before_send)

      appender.info('the secret token')
      appender.info('all clear')

      expect(otel_logger.emitted.map { |r| r[:body] }).to eq(['all clear'])
    end

    it 'drops the record (rather than sending it unscrubbed) when the callback raises' do
      before_send = proc { |_record| raise 'scrubber bug' }
      appender = described_class.new(otel_logger, level: Logger::INFO, before_send: before_send)

      expect { appender.info('the secret token') }.not_to raise_error
      expect(otel_logger.emitted).to be_empty
    end

    # Cross-SDK spec: before_send runs before the rate cap, so callback-dropped
    # records never consume window budget.
    it 'does not charge callback-dropped records against the rate-cap budget' do
      before_send = proc { |record| record[:body].include?('noise') ? nil : record }
      appender = described_class.new(
        otel_logger,
        level: Logger::INFO,
        rate_limiter: PostHog::Rails::Logs::RateLimiter.new(1),
        before_send: before_send
      )

      appender.info('noise 1')
      appender.info('noise 2')
      appender.info('keep me')

      expect(otel_logger.emitted.map { |r| r[:body] }).to eq(['keep me'])
    end

    it 'emits the cap notice directly, bypassing the callback' do
      before_send = proc { |record| record.merge(body: record[:body].upcase) }
      appender = described_class.new(
        otel_logger,
        level: Logger::INFO,
        rate_limiter: PostHog::Rails::Logs::RateLimiter.new(1),
        before_send: before_send
      )

      3.times { appender.info('msg') }

      expect(otel_logger.emitted.size).to eq(2)
      expect(otel_logger.emitted.first[:body]).to eq('MSG')
      # The notice body is untouched by the callback.
      expect(otel_logger.emitted.last[:body]).to include('rate cap reached (1 records/minute)')
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
      # Request metadata uses OTel semconv names (matching the web SDK), not
      # the $-prefixed PostHog event-property names stored in the context.
      expect(attributes['url.full']).to eq('https://example.com/widgets')
      expect(attributes['http.request.method']).to eq('GET')
      expect(attributes).not_to have_key('$current_url')
    end

    it 'omits correlation attributes when there is no active context' do
      appender.info('no context')

      attributes = otel_logger.emitted.first[:attributes]
      expect(attributes).not_to have_key('posthogDistinctId')
      expect(attributes).not_to have_key('sessionId')
    end
  end
end
