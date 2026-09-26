# frozen_string_literal: true

require 'spec_helper'
require 'io/wait'

$LOAD_PATH.unshift File.expand_path('../../../../posthog-rails/lib', __dir__)

require 'posthog/rails/logs/appender'

otel_available =
  begin
    require 'opentelemetry-logs-sdk'
    true
  rescue LoadError
    false
  end

# Preloading servers (Puma cluster mode with preload_app!, Unicorn) build the
# logs pipeline in the master via after_initialize, then fork workers — and
# threads do not survive fork, so the BatchLogRecordProcessor's worker thread
# is dead in every child. The pipeline relies on the processor's built-in
# pid-change detection to restart itself in forked workers; this spec pins
# that behavior so an OTel SDK regression (or a swap to a processor without
# fork detection) is caught in CI rather than as silently unflushed logs.
RSpec.describe 'PostHog Logs fork safety' do
  before do
    skip 'Install the gemfiles/otel.gemfile bundle to run OTel fork integration' unless otel_available
    skip 'Fork is unavailable on this platform' unless Process.respond_to?(:fork)
  end

  # Exporter that writes each record body to a pipe, so exports happening
  # inside the forked child are observable from the parent.
  let(:exporter_class) do
    Class.new do
      def initialize(io)
        @io = io
      end

      def export(records, timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
        records.each { |record| @io.puts(record.body) }
        @io.flush
        OpenTelemetry::SDK::Logs::Export::SUCCESS
      end

      def force_flush(timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
        OpenTelemetry::SDK::Logs::Export::SUCCESS
      end

      def shutdown(timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
        OpenTelemetry::SDK::Logs::Export::SUCCESS
      end
    end
  end

  it 'exports records logged in a forked worker (BatchLogRecordProcessor restarts post-fork)' do
    reader, writer = IO.pipe
    acknowledgement_reader, acknowledgement_writer = IO.pipe
    provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    provider.add_log_record_processor(
      OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(exporter_class.new(writer), schedule_delay: 10)
    )
    appender = PostHog::Rails::Logs::Appender.new(
      provider.logger(name: 'posthog-rails-test'),
      level: Logger::INFO
    )

    # Emit pre-fork so the processor's worker thread starts in the parent —
    # the preloaded-server scenario where that thread is dead in the child.
    appender.info('from parent')
    expect(provider.force_flush).to eq(OpenTelemetry::SDK::Logs::Export::SUCCESS)
    expect(reader.wait_readable(5)).not_to be_nil
    expect(reader.gets).to eq("from parent\n")

    pid = fork do
      reader.close
      acknowledgement_writer.close
      appender.info('from child')
      acknowledgement_reader.read(1)
      exit!(0) # skip at_exit/RSpec hooks inherited from the parent
    end
    acknowledgement_reader.close

    expect(reader.wait_readable(5)).not_to be_nil
    expect(reader.gets).to eq("from child\n")
    acknowledgement_writer.write('x')
    status = nil
    eventually do
      result = Process.wait2(pid, Process::WNOHANG)
      expect(result).not_to be_nil
      status = result.last
    end
    pid = nil
    expect(status).to be_success
  ensure
    if pid
      Process.kill('KILL', pid)
      Process.wait(pid)
    end
    provider&.shutdown(timeout: 1)
    [reader, writer, acknowledgement_reader, acknowledgement_writer].compact.each do |io|
      io.close unless io.closed?
    end
  end
end
