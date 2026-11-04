# frozen_string_literal: true

require_relative 'worker'

# Native counter and fixture controls run against the installed public SDK entry point.
module RubyBenchmarkControls
  def self.check(condition, message)
    raise message unless condition
  end

  def self.run
    users = RubyBenchmark::USERS
    check(users.length == 16, 'Expected 16 users')
    check(users.map { |u| u[:id] }.uniq.length == 16, 'User identities must be unique')
    users.each do |user|
      check(RubyBenchmark.expected(0, user), 'Generation zero boolean')
      check(!RubyBenchmark.expected(0, user, 1), 'Odd generation boolean')
      check(!RubyBenchmark.expected(9, user), 'Inactive flag')
      check(!RubyBenchmark.expected(8, user), 'No-match flag')
      check(!RubyBenchmark.expected(5, user, 1), 'Odd generation cohort')
      check(%w[control test].include?(RubyBenchmark.expected(2, user)), 'Variant')
      check(RubyBenchmark.expected(6, user) == RubyBenchmark.expected(7, user), 'Early and late match equivalence')
    end
    before = GC.stat(:total_allocated_objects)
    objects = Array.new(1000) { Object.new }
    allocated = GC.stat(:total_allocated_objects) - before
    check(allocated >= objects.length, 'Cumulative object counter must include live allocations')
    nil
    RubyBenchmark.settle
    check(GC.stat(:total_allocated_objects) >= before + 1000, 'GC must not reset cumulative allocations')
    snapshot = RubyBenchmark.snapshot
    check(snapshot[:rss].positive? && snapshot[:heap_used].positive?, 'Native memory counters')
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    sleep(0.002)
    check(Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) > start, 'Monotonic clock')
    check(RubyBenchmark.describe[:entry] == Gem.loaded_specs.fetch('posthog-ruby').full_gem_path,
          'Installed gem identity')
    puts 'Native fixture, allocation, memory, clock and installed-entry controls passed'
  end
end

RubyBenchmarkControls.run if $PROGRAM_NAME == __FILE__
