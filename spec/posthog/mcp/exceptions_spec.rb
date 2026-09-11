# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::Exceptions do
  it 'builds $exception_list from a Ruby exception via ExceptionCapture' do
    error = begin
      raise ArgumentError, 'bad input'
    rescue ArgumentError => e
      e
    end
    result = described_class.capture_exception(error)
    expect(result['$exception_level']).to eq('error')
    first = result['$exception_list'][0]
    expect(first['type']).to eq('ArgumentError')
    expect(first['value']).to eq('bad input')
    expect(first['stacktrace']['frames']).not_to be_empty
  end

  it 'builds a generic entry from strings and isError results' do
    expect(described_class.capture_exception('upstream timed out')['$exception_list']).to eq(
      [{ 'mechanism' => { 'type' => 'generic', 'handled' => true }, 'type' => 'Error',
         'value' => 'upstream timed out' }]
    )
    result = described_class.capture_exception('isError' => true,
                                               'content' => [{
                                                 'type' => 'text', 'text' => 'tool failed badly'
                                               }])
    expect(result['$exception_list'][0]['value']).to eq('tool failed badly')
    result = described_class.capture_exception(isError: true, content: [])
    expect(result['$exception_list'][0]['value']).to eq('Unknown error')
  end

  it 'keeps the wrapper chain and appends an original_error not on the cause chain' do
    inner = ArgumentError.new('explode')
    wrapper = MCP::Server::RequestHandlerError.new('Internal error calling tool boom', {}, original_error: inner)
    result = described_class.capture_exception(wrapper)
    types = result['$exception_list'].map { |entry| entry['type'] }
    expect(types).to eq(%w[MCP::Server::RequestHandlerError ArgumentError])
    primary = described_class.primary_exception(result)
    expect(primary['type']).to eq('ArgumentError')
    expect(primary['value']).to eq('explode')
  end

  it 'does not unwrap a wrapper without a cause' do
    wrapper = MCP::Server::RequestHandlerError.new('Internal error calling tool boom', {})
    result = described_class.capture_exception(wrapper)
    expect(described_class.primary_exception(result)['type']).to eq('MCP::Server::RequestHandlerError')
    expect(described_class.primary_exception(result)['value']).to eq('Internal error calling tool boom')
  end
end
