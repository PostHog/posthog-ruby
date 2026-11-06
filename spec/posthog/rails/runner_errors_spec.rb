# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'socket'
require 'tmpdir'

RSpec.describe 'Rails runner terminating exception capture' do
  around do |example|
    @requests = Queue.new
    @receiver = TCPServer.new('127.0.0.1', 0)
    @receiver_thread = Thread.new do
      loop do
        socket = @receiver.accept
        headers = +''
        headers << socket.read(1) until headers.end_with?("\r\n\r\n")
        length = headers[/Content-Length: (\d+)/i, 1].to_i
        @requests << JSON.parse(socket.read(length))
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        socket.close
      end
    end
    example.run
  ensure
    @receiver_thread&.kill
    @receiver_thread&.join
    @receiver&.close
  end

  def run_application(code, setup: '', initialize_client: true, runner: true, runner_options: [])
    Dir.mktmpdir('posthog-runner') do |root|
      Dir.mkdir(File.join(root, 'config'))
      File.write(File.join(root, 'config/application.rb'), <<~RUBY)
        require 'rails'
        require 'action_controller/railtie'
        require 'posthog'
        require 'posthog/rails'
        class RunnerTestApplication < Rails::Application
          config.root = #{root.inspect}
          config.eager_load = false
          config.secret_key_base = 'runner-test-secret'
          config.logger = Logger.new(File::NULL)
          initializer 'runner_test.posthog' do
            PostHog::Rails.config.auto_capture_exceptions = true
            host = 'http://127.0.0.1:#{@receiver.addr[1]}'
            if #{initialize_client}
              PostHog.init(api_key: 'phc_test', host: host,
                           compress_request: false, batch_size: 1000, flush_interval_seconds: 3600)
            end
            #{setup}
          end
        end
      RUBY
      File.write(File.join(root, 'config/environment.rb'), <<~RUBY)
        require_relative 'application'
        Rails.application.initialize!
      RUBY
      script = File.join(root, 'failure.rb')
      File.write(script, code)
      bootstrap = if runner
                    "APP_PATH = #{File.join(root, 'config/application.rb').inspect}; require 'rails/commands'"
                  else
                    "require #{File.join(root, 'config/environment.rb').inspect}; load #{script.inspect}"
                  end
      Open3.capture3(
        { 'RAILS_ENV' => 'test' }, RbConfig.ruby, '-Ilib', '-Iposthog-rails/lib', '-e', bootstrap,
        *(runner ? ['--', 'runner', *runner_options, script] : [])
      )
    end
  end

  def received_events
    batches = []
    batches << @requests.pop until @requests.empty?
    batches.flat_map { |request| request.fetch('batch') }
  end

  it 'delivers the original exception before shutdown using the queued transport' do
    stdout, stderr, status = run_application("puts 'runner began'; raise ArgumentError, 'original runner failure'")

    expect(status.exitstatus).to eq(1), stderr
    expect(stdout).to include('runner began')
    expect(stderr).to include('original runner failure (ArgumentError)', 'failure.rb:1')
    events = received_events
    expect(events.length).to eq(1)
    expect(events.first['event']).to eq('$exception')
    properties = events.first.fetch('properties')
    expect(properties).to include('$exception_level' => 'fatal', '$exception_source' => 'rails.runner')
    exception = properties.fetch('$exception_list').first
    expect(exception).to include('type' => 'ArgumentError', 'value' => 'original runner failure')
    expect(exception.fetch('mechanism')).to include('type' => 'at_exit', 'handled' => false, 'synthetic' => false)
    expect(exception.fetch('stacktrace').fetch('frames').last.fetch('filename')).to end_with('failure.rb')
  end

  { 'normal completion' => "puts 'done'", 'successful SystemExit' => 'exit 0' }.each do |name, code|
    it "does not report #{name}" do
      _stdout, stderr, status = run_application(code)

      expect(status).to be_success, stderr
      expect(received_events).to eq([])
    end
  end

  it 'captures a runner failure without executor error reporting' do
    require 'rails'
    skip 'Runner executor opt-out requires Rails 7.2+' if Gem::Version.new(Rails.version) < Gem::Version.new('7.2')

    _stdout, stderr, status = run_application("raise 'without executor'", runner_options: ['--skip-executor'])

    expect(status.exitstatus).to eq(1), stderr
    events = received_events
    expect(events.length).to eq(1)
    expect(events.first.fetch('properties')).to include('$exception_source' => 'rails.runner')
  end

  it 'captures a failure from a later exit hook before SDK shutdown' do
    _stdout, stderr, status = run_application("at_exit { raise 'late runner failure' }")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('late runner failure (RuntimeError)')
    expect(received_events.length).to eq(1)
  end

  it 'reports a failing SystemExit without changing its status or output' do
    _stdout, stderr, status = run_application("warn 'requested failure'; exit 23")

    expect(status.exitstatus).to eq(23)
    expect(stderr).to eq("requested failure\n")
    expect(received_events.length).to eq(1)
  end

  {
    'disabled automatic capture' => 'PostHog::Rails.config.auto_capture_exceptions = false',
    'excluded exceptions' => "PostHog::Rails.config.excluded_exceptions = ['RuntimeError']",
    'disabled client' => "PostHog.init(api_key: '', silence_disabled_client_error: true)",
    'before_send drop' => "PostHog.init(api_key: 'phc_test', host: host, before_send: ->(_event) { nil })",
    'before_send failure' => "PostHog.init(api_key: 'phc_test', host: host, " \
                             "before_send: ->(_event) { raise 'scrubber failed' })"
  }.each do |name, setup|
    it "respects #{name} and preserves the original failure" do
      _stdout, stderr, status = run_application("raise 'original runner failure'", setup: setup)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('original runner failure (RuntimeError)')
      expect(received_events).to eq([])
    end
  end

  it 'preserves exception output byte-for-byte compared with disabled capture' do
    code = <<~RUBY
      error = ArgumentError.new('original runner failure')
      error.set_backtrace(["runner-original.rb:42:in `boom'"])
      raise error
    RUBY
    _stdout, original_stderr, original_status = run_application(
      code, setup: 'PostHog::Rails.config.auto_capture_exceptions = false'
    )
    _stdout, captured_stderr, captured_status = run_application(code)

    expect(captured_status.exitstatus).to eq(original_status.exitstatus)
    expect(captured_stderr).to eq(original_stderr)
    expect(received_events.length).to eq(1)
  end

  it 'does not create a default client when the application never initialized PostHog' do
    setup = <<~RUBY
      at_exit { warn "initialized after shutdown: \#{PostHog.initialized?}" }
    RUBY
    _stdout, stderr, status = run_application("raise 'uninitialized failure'", setup: setup, initialize_client: false)

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('uninitialized failure (RuntimeError)', 'initialized after shutdown: false')
    expect(received_events).to eq([])
  end

  it 'does not capture terminating errors in a non-runner application' do
    _stdout, stderr, status = run_application("raise 'web process failure'", runner: false)

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('web process failure (RuntimeError)')
    expect(received_events).to eq([])
  end

  it 'does not duplicate an exception already captured through the client' do
    code = <<~RUBY
      begin
        raise 'already reported'
      rescue StandardError => error
        PostHog.capture_exception(error)
        raise
      end
    RUBY
    _stdout, stderr, status = run_application(code)

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('already reported (RuntimeError)')
    expect(received_events.length).to eq(1)
  end

  it 'preserves a failing exit status even if reporting tries to exit successfully' do
    setup = <<~RUBY
      client = PostHog.client
      def client.capture_exception(*)
        exit 0
      end
    RUBY
    _stdout, stderr, status = run_application('exit 23', setup: setup)

    expect(status.exitstatus).to eq(23)
    expect(stderr).to eq('')
    expect(received_events).to eq([])
  end

  it 'preserves the original failure if reporting raises and still shuts down' do
    setup = <<~RUBY
      client = PostHog.client
      def client.capture_exception(*)
        raise 'reporting failed'
      end
      PostHog.capture(event: 'pending event', distinct_id: 'runner-test')
    RUBY
    _stdout, stderr, status = run_application("raise 'original runner failure'", setup: setup)

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('original runner failure (RuntimeError)')
    expect(stderr).not_to include('reporting failed (RuntimeError)')
    expect(received_events.map { |event| event['event'] }).to eq(['pending event'])
  end
end
