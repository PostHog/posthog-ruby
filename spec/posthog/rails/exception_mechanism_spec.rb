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
  end
end
