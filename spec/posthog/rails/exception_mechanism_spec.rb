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

  before do
    allow(PostHog).to receive(:capture_exception)
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
      allow(PostHog).to receive(:capture_exception).and_return(true)
      app = ->(_env) { raise StandardError, 'boom' }
      middleware = described_class.new(app)
      env = Rack::MockRequest.env_for('/api/test')
      error = nil

      begin
        middleware.call(env)
      rescue StandardError => e
        error = e
      end

      # ActionDispatch::Executor sits above this middleware and reports to
      # Rails.error only after the response has unwound past it, so the
      # in-web-request flag is already cleared by the time the report lands.
      expect(PostHog::Rails.in_web_request?).to be(false)

      PostHog::Rails::ErrorSubscriber.new.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.action_dispatch'
      )

      expect(PostHog).to have_received(:capture_exception).once
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
      PostHog::Rails.mark_active_job_exception_captured(error)

      described_class.new.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.active_support'
      )

      expect(PostHog).not_to have_received(:capture_exception)
    end

    it 'skips exceptions already captured by CaptureExceptions' do
      error = StandardError.new('boom')
      PostHog::Rails.mark_web_exception_captured(error)

      described_class.new.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.action_dispatch'
      )

      expect(PostHog).not_to have_received(:capture_exception)
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

      PostHog::Rails.mark_web_exception_captured(wrapped)

      # ActionDispatch::ExceptionWrapper unwraps ActionView::Template::Error to
      # its cause, so Rails reports a different object than the one captured.
      described_class.new.report(
        wrapped.cause,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.action_dispatch'
      )

      expect(PostHog).not_to have_received(:capture_exception)
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

      PostHog::Rails::ErrorSubscriber.new.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: 'application.active_support'
      )

      expect(PostHog).to have_received(:capture_exception).once
      expect(PostHog).to have_received(:capture_exception).with(
        an_instance_of(StandardError),
        anything,
        hash_including('$exception_source' => 'active_job'),
        mechanism: { 'type' => 'active_job', 'handled' => false }
      )
    end
  end
end
