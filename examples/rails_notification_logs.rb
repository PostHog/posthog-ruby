# frozen_string_literal: true

# Run with the gemfiles/otel.gemfile bundle and POSTHOG_API_KEY set.
require 'json'
require 'securerandom'
require 'tmpdir'
require 'rails'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'rack/mock'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../posthog-rails/lib', __dir__)
require 'posthog'
require 'posthog/rails'

module NotificationLogsExample
  RUN_ID = ENV.fetch('POSTHOG_RUN_ID') { "ruby-pr337-#{SecureRandom.uuid}" }
  SESSION_ID = SecureRandom.uuid

  def self.records
    @records ||= []
  end

  class Application < Rails::Application
    config.eager_load = false
    config.secret_key_base = SecureRandom.hex(64)
    config.hosts.clear
    config.logger = ActiveSupport::Logger.new($stdout)
    config.filter_parameters += [:password]
    config.active_job.queue_adapter = :inline

    initializer 'example.posthog' do
      PostHog.init(
        api_key: ENV.fetch('POSTHOG_API_KEY'),
        host: ENV.fetch('POSTHOG_HOST', 'https://us.i.posthog.com'),
        on_error: proc { |status, message| warn "PostHog delivery failed: #{status} #{message}" }
      )
      PostHog::Rails.configure do |config|
        config.logs_enabled = true
        config.logs_forward_rails_logger = false
        config.logs_notifications = %i[action_controller active_job]
        config.logs_level = :debug
        config.auto_instrument_active_job = true
        config.logs_before_send = proc do |record|
          record[:attributes]['validation.run_id'] = RUN_ID
          next if record[:attributes]['http.response.status_code'] == 418

          NotificationLogsExample.records << record
          record
        end
      end
    end
  end

  class ExampleJob < ActiveJob::Base
    def perform(_details, _unkeyed_secret)
      PostHog.capture(event: 'rails_notification_logs_job', properties: { validation_run_id: RUN_ID })
    end
  end

  class ExampleController < ActionController::Base
    def index
      ExampleJob.perform_later({ visible: 'example', password: 'PRIVATE_JOB_PASSWORD' }, 'PRIVATE_UNKEYED')
      PostHog.capture(event: 'rails_notification_logs_request', properties: { validation_run_id: RUN_ID })
      render plain: 'ok', status: params.fetch(:status, 200).to_i
    end
  end
end

Dir.mktmpdir('posthog-notification-logs') do |root|
  NotificationLogsExample::Application.config.root = root
  NotificationLogsExample::Application.initialize!
  Rails.application.routes.draw do
    get '/notification_logs', to: 'notification_logs_example/example#index'
  end

  require 'opentelemetry-sdk'
  span_context = OpenTelemetry::Trace::SpanContext.new(trace_id: SecureRandom.random_bytes(16),
                                                       span_id: SecureRandom.random_bytes(8))
  span = OpenTelemetry::Trace.non_recording_span(span_context)
  request = Rack::MockRequest.new(Rails.application)
  OpenTelemetry::Trace.with_span(span) do
    [200, 422, 500, 418].each do |status|
      response = request.get(
        "/notification_logs?status=#{status}&visible=example&password=PRIVATE_REQUEST_PASSWORD",
        'HTTP_X_POSTHOG_DISTINCT_ID' => NotificationLogsExample::RUN_ID,
        'HTTP_X_POSTHOG_SESSION_ID' => NotificationLogsExample::SESSION_ID
      )
      raise "Unexpected response: #{response.status} != #{status}" unless response.status == status
    end
  end
  Rails.logger.info('PRIVATE_GENERIC_LOG_NOT_FORWARDED')

  records = NotificationLogsExample.records
  raise "Unexpected log count: #{records.size}" unless records.size == 11
  raise 'Unfiltered private data in log records' if JSON.generate(records).include?('PRIVATE_')

  provider = PostHog::Rails::Logs::Setup.provider
  raise 'PostHog Logs did not initialize' unless provider
  raise 'Log export failed' unless provider.force_flush == OpenTelemetry::SDK::Logs::Export::SUCCESS

  PostHog.flush
  puts JSON.pretty_generate(
    run_id: NotificationLogsExample::RUN_ID,
    session_id: NotificationLogsExample::SESSION_ID,
    trace_id: span_context.hex_trace_id,
    span_id: span_context.hex_span_id,
    expected_logs: 11,
    expected_events: 8,
    host: ENV.fetch('POSTHOG_HOST', 'https://us.i.posthog.com')
  )
end
