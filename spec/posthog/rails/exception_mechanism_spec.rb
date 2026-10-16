# frozen_string_literal: true

require 'spec_helper'
require 'rails'
require 'rails/railtie'
require 'action_dispatch'
require 'rack/mock'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)

require 'posthog/rails'

RSpec.describe 'automatic exception capture mechanisms' do
  around do |example|
    previous_config = PostHog::Rails.config
    PostHog::Rails.config = PostHog::Rails::Configuration.new
    PostHog::Rails.config.auto_capture_exceptions = true
    example.run
  ensure
    PostHog::Rails.config = previous_config
  end

  let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }

  before do
    allow(PostHog).to receive(:client).and_return(client)
    allow(PostHog).to receive(:capture_exception).and_call_original
  end

  describe 'Rails error reports during requests' do
    let(:reporter) { ActiveSupport::ErrorReporter.new.tap { |r| r.subscribe(PostHog::Rails::ErrorSubscriber.new) } }

    it 'captures handled errors with the existing request and reporter context' do
      app = lambda do |_env|
        reporter.handle(context: { distinct_id: 'shop-123', shop_id: 123 }) { raise 'handled' }
        [200, {}, []]
      end
      middleware = PostHog::Rails::RequestContext.new(PostHog::Rails::CaptureExceptions.new(app))
      middleware.call(Rack::MockRequest.env_for('/orders'))

      expect(client.queued_messages).to eq(1)
      event = client.dequeue_last_message
      expect(event[:distinct_id]).to eq('shop-123')
      expect(event[:properties]).to include('$request_path' => '/orders', '$context_shop_id' => 123)
      expect(event[:properties]['$exception_list'].first['mechanism']['handled']).to be(true)
    end

    it 'does not duplicate an error reported before it escapes the request' do
      app = ->(_env) { reporter.record { raise 'unhandled' } }
      middleware = PostHog::Rails::CaptureExceptions.new(app)

      expect { middleware.call(Rack::MockRequest.env_for('/orders')) }.to raise_error('unhandled')
      expect(client.queued_messages).to eq(1)
      expect(client.dequeue_last_message[:properties]['$exception_list'].first['mechanism']['handled']).to be(false)
    end
  end

  describe PostHog::Rails::CaptureExceptions do
    it 'tags middleware captures as unhandled rails exceptions' do
      app = ->(_env) { raise StandardError, 'boom' }
      middleware = described_class.new(app)
      env = Rack::MockRequest.env_for('/api/test')

      expect { middleware.call(env) }.to raise_error(StandardError, 'boom')

      expect(PostHog).to have_received(:capture_exception).with(
        an_instance_of(StandardError),
        anything,
        an_instance_of(Hash),
        mechanism: { 'type' => 'rails', 'handled' => false }
      )
    end

    it 'prevents the Rails error subscriber from capturing the same web exception again' do
      app = ->(_env) { raise StandardError, 'boom' }
      middleware = described_class.new(app)
      env = Rack::MockRequest.env_for('/api/test')
      error = nil

      begin
        middleware.call(env)
      rescue StandardError => e
        error = e
      end

      PostHog::Rails::ErrorSubscriber.new.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.action_dispatch'
      )

      expect(client.queued_messages).to eq(1)
      expect(PostHog).to have_received(:capture_exception).with(
        an_instance_of(StandardError),
        anything,
        hash_including('$exception_source' => 'rails'),
        mechanism: { 'type' => 'rails', 'handled' => false }
      )
    end

    it 'allows the Rails error subscriber to retry when the web capture was not queued' do
      allow(PostHog).to receive(:capture_exception).and_return(false, true)
      app = ->(_env) { raise StandardError, 'boom' }
      middleware = described_class.new(app)
      env = Rack::MockRequest.env_for('/api/test')
      error = nil

      begin
        middleware.call(env)
      rescue StandardError => e
        error = e
      end

      PostHog::Rails::ErrorSubscriber.new.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.action_dispatch'
      )

      expect(PostHog).to have_received(:capture_exception).twice
      expect(PostHog).to have_received(:capture_exception).with(
        error,
        anything,
        hash_including('$exception_source' => 'application.action_dispatch'),
        mechanism: { 'type' => 'rails_error_reporter', 'handled' => false }
      )
    end
  end

  describe PostHog::Rails::ErrorSubscriber do
    [
      { handled: true, severity: :warning, description: 'forwards the handled flag reported by Rails' },
      { handled: false, severity: :error, description: 'tags unhandled reports as unhandled' }
    ].each do |scenario|
      it scenario[:description] do
        described_class.new.report(
          StandardError.new('boom'),
          handled: scenario[:handled],
          severity: scenario[:severity],
          context: {}
        )

        expect(PostHog).to have_received(:capture_exception).with(
          an_instance_of(StandardError),
          anything,
          an_instance_of(Hash),
          mechanism: { 'type' => 'rails_error_reporter', 'handled' => scenario[:handled] }
        )
      end
    end

    it 'skips exceptions already captured by ActiveJobExtensions' do
      PostHog::Rails.config.auto_instrument_active_job = true
      error = StandardError.new('boom')
      client.capture_exception(error)

      described_class.new.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.active_support'
      )

      expect(client.queued_messages).to eq(1)
    end

    it 'skips exceptions already captured by CaptureExceptions' do
      error = StandardError.new('boom')
      client.capture_exception(error)

      described_class.new.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.action_dispatch'
      )

      expect(client.queued_messages).to eq(1)
    end

    it 'skips the unwrapped cause of an exception already captured by CaptureExceptions' do
      wrapped = begin
        raise 'original'
      rescue StandardError
        begin
          raise 'wrapped'
        rescue StandardError => e
          e
        end
      end

      client.capture_exception(wrapped)

      # ActionDispatch::ExceptionWrapper unwraps ActionView::Template::Error to
      # its cause, so Rails reports a different object than the one captured.
      described_class.new.report(
        wrapped.cause,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.action_dispatch'
      )

      expect(client.queued_messages).to eq(1)
    end

    it 'still captures unmarked ActiveSupport reports when ActiveJob instrumentation is enabled' do
      PostHog::Rails.config.auto_instrument_active_job = true

      described_class.new.report(
        StandardError.new('boom'),
        handled: false,
        severity: :error,
        context: {},
        source: 'application.active_support'
      )

      expect(PostHog).to have_received(:capture_exception).with(
        an_instance_of(StandardError),
        anything,
        hash_including('$exception_source' => 'application.active_support'),
        mechanism: { 'type' => 'rails_error_reporter', 'handled' => false }
      )
    end
  end

  describe PostHog::Rails::ActiveJobExtensions do
    let(:job_class) do
      extensions = described_class
      Class.new do
        prepend extensions

        def self.name
          'FakeJob'
        end

        def job_id
          'job-1'
        end

        def queue_name
          'default'
        end

        def priority
          nil
        end

        def executions
          1
        end

        def arguments
          []
        end

        def perform_now
          raise StandardError, 'job failed'
        end
      end
    end

    it 'tags job captures as unhandled active_job exceptions' do
      PostHog::Rails.config.auto_instrument_active_job = true

      expect { job_class.new.perform_now }.to raise_error(StandardError, 'job failed')

      expect(PostHog).to have_received(:capture_exception).with(
        an_instance_of(StandardError),
        anything,
        an_instance_of(Hash),
        mechanism: { 'type' => 'active_job', 'handled' => false }
      )
    end

    it 'prevents Rails error subscriber from capturing the same job exception again' do
      PostHog::Rails.config.auto_instrument_active_job = true
      error = nil

      begin
        job_class.new.perform_now
      rescue StandardError => e
        error = e
      end

      expect(error).to be_a(StandardError)
      expect(error.message).to eq('job failed')
      PostHog::Rails::ErrorSubscriber.new.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.active_support'
      )

      expect(client.queued_messages).to eq(1)
      expect(client.dequeue_last_message[:properties]).to include('$job_class' => 'FakeJob', '$job_id' => 'job-1')
      expect(PostHog).to have_received(:capture_exception).with(
        an_instance_of(StandardError),
        anything,
        hash_including('$exception_source' => 'active_job'),
        mechanism: { 'type' => 'active_job', 'handled' => false }
      )
    end

    it 'allows a Rails report to retry when the job event was dropped' do
      PostHog::Rails.config.auto_instrument_active_job = true
      attempts = 0
      retry_client = PostHog::Client.new(api_key: API_KEY, test_mode: true, before_send: lambda { |event|
        attempts += 1
        event if attempts > 1
      })
      allow(PostHog).to receive(:client).and_return(retry_client)

      expect { job_class.new.perform_now }.to raise_error(StandardError, 'job failed') do |error|
        PostHog::Rails::ErrorSubscriber.new.report(error, handled: false, severity: :error, context: {})
      end

      expect(retry_client.queued_messages).to eq(1)
    end
  end
end
