# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Analytics do
  let(:client) { new_test_client }
  let(:log) { [] }
  let(:server) { MCP::Server.new(name: 'spec-server', version: '1.0.0', tools: []) }
  let(:analytics) { PostHog::MCP.instrument(server, client, logger: ->(message) { log << message }) }

  before { allow(Kernel).to receive(:warn) }

  describe '#flush' do
    [
      [{}, 10],
      [{ timeout: 2.5 }, 2.5]
    ].each do |kwargs, expected_timeout|
      it "bounds the client flush with timeout #{expected_timeout} when called with #{kwargs}" do
        expect(client).to receive(:flush).with(timeout: expected_timeout).and_return(true)

        analytics.flush(**kwargs)
      end
    end

    [
      ['raises', -> { raise IOError, 'socket closed' }, 'Failed to flush PostHog client: IOError: socket closed'],
      ['times out', -> { false }, 'PostHog client flush did not finish within 10s']
    ].each do |label, behavior, logged|
      it "returns nil and logs when the client flush #{label}" do
        allow(client).to receive(:flush) { behavior.call }

        expect(analytics.flush).to be_nil
        expect(log).to include(logged)
      end
    end
  end
end
