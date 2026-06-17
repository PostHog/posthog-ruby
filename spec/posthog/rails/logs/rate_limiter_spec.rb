# frozen_string_literal: true

require 'spec_helper'

$LOAD_PATH.unshift File.expand_path('../../../../posthog-rails/lib', __dir__)

require 'posthog/rails/logs/rate_limiter'

RSpec.describe PostHog::Rails::Logs::RateLimiter do
  subject(:limiter) { described_class.new(3) }

  def stub_monotonic_time(seconds)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(seconds)
  end

  it 'allows records up to the limit' do
    stub_monotonic_time(0)

    expect(Array.new(3) { limiter.record }).to all(eq(:allow))
  end

  it 'returns :reject_first exactly once per window, then :reject' do
    stub_monotonic_time(0)
    3.times { limiter.record }

    expect(limiter.record).to eq(:reject_first)
    expect(limiter.record).to eq(:reject)
    expect(limiter.record).to eq(:reject)
  end

  it 'resets the counter in a new window' do
    stub_monotonic_time(0)
    4.times { limiter.record }
    expect(limiter.record).to eq(:reject)

    stub_monotonic_time(described_class::WINDOW_SECONDS)
    expect(limiter.record).to eq(:allow)
  end

  it 'counts concurrent records without losing increments' do
    stub_monotonic_time(0)
    limiter = described_class.new(100)

    threads = Array.new(4) { Thread.new { Array.new(50) { limiter.record } } }
    verdicts = threads.flat_map(&:value)

    expect(verdicts.count(:allow)).to eq(100)
    expect(verdicts.count(:reject_first)).to eq(1)
    expect(verdicts.count(:reject)).to eq(99)
  end
end
