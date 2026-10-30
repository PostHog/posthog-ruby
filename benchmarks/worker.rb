# frozen_string_literal: true

require 'json'
require 'net/http'
require 'digest'
require 'objspace'
require 'logger'
require 'rbconfig'

gem 'concurrent-ruby', ENV.fetch('BENCHMARK_CONCURRENT_VERSION')
gem 'posthog-ruby', ENV.fetch('BENCHMARK_SDK_VERSION')
require 'posthog'

module RubyBenchmark
  CASES = %w[boolean rollout variant property regex cohort early late no-match inactive].freeze
  USERS = Array.new(16) do |i|
    { id: "benchmark-user-#{i}", properties: { plan: i.even? ? 'pro' : 'free',
                                               email: "user-#{i}@example.test", score: i } }
  end.freeze

  def self.require_condition(condition, message)
    raise message unless condition
  end

  def self.expected(index, user, generation = 0)
    kind = CASES[index % 10]
    return generation.even? if kind == 'boolean'
    return false if %w[inactive no-match].include?(kind) || (kind == 'cohort' && generation.odd?)
    return user[:properties][:plan] == 'pro' if %w[property cohort early late].include?(kind)

    if %w[rollout variant].include?(kind)
      salt = kind == 'variant' ? 'variant' : ''
      bucket = Digest::SHA1.hexdigest("#{kind}-#{index}.#{user[:id]}#{salt}")[0, 15].to_i(16).to_f / ((2**60) - 1)
      return bucket < 0.5 if kind == 'rollout'

      return bucket < 0.5 ? 'control' : 'test'
    end
    true
  end

  def self.settle
    GC.start
    Thread.pass
    GC.start
  end

  def self.snapshot
    # ObjectSpace reports retained live-object bytes, not cumulative allocation volume.
    heap = ObjectSpace.memsize_of_all
    rss = if File.file?('/proc/self/status')
            File.read('/proc/self/status')[/^VmRSS:\s+(\d+)/, 1].to_i * 1024
          else
            IO.popen(['ps', '-o', 'rss=', '-p', Process.pid.to_s], &:read).to_i * 1024
          end
    require_condition(rss.positive?, 'RSS counter unavailable')
    { rss: rss, heap_used: heap }
  end

  def self.describe
    {
      runtime: RUBY_ENGINE, runtime_version: RUBY_VERSION, os: RbConfig::CONFIG['host_os'],
      arch: RbConfig::CONFIG['host_cpu'],
      cpu: if File.file?('/proc/cpuinfo')
             File.read('/proc/cpuinfo')[/^model name\s*:\s*(.+)/, 1] || 'unknown'
           else
             IO.popen(['sysctl', '-n', 'machdep.cpu.brand_string'], &:read).strip
           end,
      kernel: IO.popen(['uname', '-r'], &:read).strip,
      sdk_version: PostHog::VERSION,
      entry: Gem.loaded_specs.fetch('posthog-ruby').full_gem_path,
      packages: { 'concurrent-ruby' => Concurrent::VERSION },
      measurement_tools: { ruby: RUBY_DESCRIPTION, objectspace: 'stdlib' }
    }
  end

  class Workload
    def initialize(spec, url)
      @spec = spec
      @url = url
      @generation = 0
      @captured = 0
      @errors = []
      @client = PostHog::Client.new(
        api_key: 'benchmark-project', secret_key: spec.key?('flag_count') ? 'benchmark-secret' : nil,
        host: url, batch_size: 100_000, max_queue_size: 100_001, flush_interval_seconds: 3600,
        feature_flags_polling_interval: 3600, compress_request: false, max_retries: 0,
        feature_flag_request_max_retries: 0, disable_singleton_warning: true,
        on_error: ->(status, error) { @errors << [status, error.to_s[0, 300]] if @errors.length < 10 }
      )
    end

    def control(path, value = nil)
      uri = URI("#{@url}/__benchmark/#{path}")
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.open_timeout = http.read_timeout = 5
      request = value ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request.body = JSON.generate(value) if value
      response = http.request(request)
      RubyBenchmark.require_condition(response.code == '200', 'Benchmark control failed')
      JSON.parse(response.body)
    end

    def reload(generation)
      control('definitions', { generation: generation })
      @client.reload_feature_flags
      @generation = generation
    end

    def all_flags(user)
      @client.get_all_flags(user[:id], person_properties: user[:properties], only_evaluate_locally: true)
    end

    def single_flag(user)
      index = @spec.fetch('flag_index')
      @client.get_feature_flag(
        "#{CASES[index]}-#{index}", user[:id], person_properties: user[:properties],
                                               only_evaluate_locally: true, send_feature_flag_events: false
      )
    end

    def prepare_events(operations)
      @events = Array.new(operations) do |i|
        { event: 'benchmark', distinct_id: USERS[i % 16][:id],
          properties: { payload: 'x' * @spec.fetch('payload_bytes'), plan: 'pro', sequence: i } }
      end
    end

    def run(operations)
      mode = @spec.fetch('mode')
      if mode == 'refresh'
        operations.times do |i|
          reload(i + 1)
          yield(i + 1) if block_given?
        end
      elsif %w[capture drain].include?(mode)
        operations.times do |i|
          RubyBenchmark.require_condition(@client.capture(@events[i]), 'Capture rejected')
          @captured += 1
          flush if mode == 'drain' && @spec['drain_strategy'] == 'steady' &&
                   (((i + 1) % @spec['flush_every']).zero? || i + 1 == operations)
          yield(i + 1) if block_given? && ((i + 1) % 100).zero?
        end
        flush if mode == 'drain' && @spec['drain_strategy'] == 'burst'
      elsif @spec.fetch('concurrency') > 1
        # Join in deterministic 32-operation groups, preserving native GVL-constrained threads.
        operations.times.each_slice(32) do |positions|
          threads = positions.each_slice(4).map do |slice|
            Thread.new { slice.each { |i| all_flags(USERS[i % 16]) } }
          end
          threads.each(&:value)
          yield(positions.last + 1) if block_given?
        end
      else
        operations.times do |i|
          mode == 'single' ? single_flag(USERS[i % 16]) : all_flags(USERS[i % 16])
        end
      end
    end

    def flush
      RubyBenchmark.require_condition(@client.flush(timeout: 10), 'Public flush timed out')
    end

    def verify
      RubyBenchmark.require_condition(@errors.empty?, "SDK callback errors: #{@errors.inspect}")
      state = control('state')
      RubyBenchmark.require_condition(state.fetch('unexpected').empty?, 'Unexpected network request')
      if @spec.key?('flag_count')
        RubyBenchmark.require_condition(@client.feature_flags_loaded?, 'Flag definitions not loaded')
        USERS.each do |user|
          expected = @spec['flag_count'].times.to_h do |i|
            ["#{CASES[i % 10]}-#{i}", RubyBenchmark.expected(i, user, @generation)]
          end
          actual = all_flags(user)
          RubyBenchmark.require_condition(actual == expected, 'All-flags correctness mismatch')
          next unless @spec['mode'] == 'single'

          i = @spec.fetch('flag_index')
          RubyBenchmark.require_condition(single_flag(user) == RubyBenchmark.expected(i, user, @generation),
                                          'Single-flag correctness mismatch')
        end
        if @spec['mode'] == 'refresh'
          RubyBenchmark.require_condition(state.fetch('definitions') == @generation,
                                          'Reload did not request definitions')
        end
      else
        expected_counts = USERS.each_with_index.to_h do |user, i|
          [user[:id], (@captured / 16) + (i < @captured % 16 ? 1 : 0)]
        end
        valid = state['delivered'] == @captured && state['invalid_events'].zero? &&
                state['unique_sequences'] == @captured && state['missing_sequences'].zero? &&
                state['delivered_by_user'] == expected_counts
        RubyBenchmark.require_condition(valid, 'Capture payload, identity or sequence mismatch')
      end
    end

    def prepare(operations)
      warmup = if @spec['mode'] == 'refresh'
                 2
               else
                 [operations, @spec['flag_count'] == 1000 ? 32 : 160].min
               end
      control('reset', { operations: @spec.key?('payload_bytes') ? warmup : 0 })
      prepare_events(warmup) if @spec.key?('payload_bytes')
      run(warmup)
      flush if @spec['mode'] == 'capture'
      verify
      reload(0) if @spec.key?('flag_count')
      control('reset', { operations: @spec.key?('payload_bytes') ? operations : 0 })
      @captured = 0
      prepare_events(operations) if @spec.key?('payload_bytes')
      warmup
    end

    def complete
      # Enqueue-only verification flush is outside measurement. Delivery verification never rescues a flush.
      flush if @spec['mode'] == 'capture'
      verify
    end

    def close
      RubyBenchmark.require_condition(@client.shutdown(timeout: 10), 'Public shutdown timed out')
    end
  end

  def self.measure(spec, url)
    operations = if spec['pass'] == 'allocation'
                   spec.fetch('allocation_operations',
                              spec['operations'])
                 else
                   spec['operations']
                 end
    workload = Workload.new(spec, url)
    begin
      warmup = workload.prepare(operations)
      settle
      result = { status: 'ok', pass: spec['pass'], operations: operations, warmup_operations: warmup }
      case spec['pass']
      when 'timing'
        cpu_clock = spec['mode'] == 'capture' ? Process::CLOCK_THREAD_CPUTIME_ID : Process::CLOCK_PROCESS_CPUTIME_ID
        cpu = Process.clock_gettime(cpu_clock, :nanosecond)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        workload.run(operations)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - start
        cpu = Process.clock_gettime(cpu_clock, :nanosecond) - cpu
        result.merge!(elapsed_ns: elapsed, elapsed_time_per_op: elapsed.to_f / operations,
                      cpu_time_per_op: cpu.to_f / operations)
      when 'allocation'
        before = GC.stat(:total_allocated_objects)
        workload.run(operations)
        result[:allocated_objects] = GC.stat(:total_allocated_objects) - before
      when 'memory'
        before = snapshot
        checkpoints = []
        workload.run(operations) { |i| checkpoints << { operations: i, **snapshot } }
        if checkpoints.empty? || checkpoints.last[:operations] != operations
          checkpoints << { operations: operations,
                           **snapshot }
        end
        after = snapshot
        settle
        after_settling = snapshot
        high_water = if File.file?('/proc/self/status')
                       File.read('/proc/self/status')[/^VmHWM:\s+(\d+)/,
                                                      1].to_i * 1024
                     end
        result.merge!(before: before, after: after, after_settling: after_settling, checkpoints: checkpoints,
                      observed_peak_rss: [before[:rss], after[:rss], *checkpoints.map { |p| p[:rss] }].max,
                      process_lifetime_peak_rss: high_water)
      else
        raise 'Unknown measurement pass'
      end
      workload.complete
      result
    ensure
      workload.close
    end
  end
end

if $PROGRAM_NAME == __FILE__
  PostHog::Logging.logger = Logger.new(File::NULL)
  if ARGV == ['--describe']
    puts JSON.generate(RubyBenchmark.describe)
  else
    spec_path, url, output = ARGV
    spec = JSON.parse(File.read(spec_path))
    result = RubyBenchmark.measure(spec, url)
    File.write(output, JSON.generate(result))
  end
end
