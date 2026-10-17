# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'posthog/otel/context_span_processor'

RSpec.describe PostHog::ContextSpanProcessor do
  it 'loads and runs without loading optional OpenTelemetry gems' do
    script = <<~RUBY
      require 'posthog'
      require 'posthog/otel/context_span_processor'
      context = PostHog.const_get(:Internal).const_get(:Context)
      context.with_context(distinct_id: 'local-person', session_id: 'local-session') do
        raise 'context missing' unless context.current.distinct_id == 'local-person'
      end
      raise 'context leaked' unless context.current.nil?
      raise 'OpenTelemetry loaded' if defined?(OpenTelemetry)
      processor = PostHog::ContextSpanProcessor.new
      raise 'flush failed' unless processor.force_flush(timeout: 1) == 0
      raise 'shutdown failed' unless processor.shutdown(timeout: 1) == 0
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', script)

    expect(status.success?).to be(true), output
  end

  it 'does not let a failed context lookup break application tracing' do
    context = PostHog.const_get(:Internal).const_get(:Context)
    allow(context).to receive(:current).and_raise('context unavailable')

    expect { described_class.new.on_start(nil, nil) }.not_to raise_error
  end
end
