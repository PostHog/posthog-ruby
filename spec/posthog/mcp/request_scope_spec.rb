# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::RequestScope do
  describe '.headers_from_env' do
    {
      'a prefixed header' => [{ 'HTTP_AUTHORIZATION' => 'Bearer t' }, { 'authorization' => 'Bearer t' }],
      'a multi-word header' => [{ 'HTTP_X_TENANT_ID' => 'acme' }, { 'x-tenant-id' => 'acme' }],
      'the headers Rack stores unprefixed' => [{ 'CONTENT_TYPE' => 'application/json', 'CONTENT_LENGTH' => '42' },
                                               { 'content-type' => 'application/json', 'content-length' => '42' }],
      'the protocol some servers store as HTTP_VERSION' => [{ 'HTTP_VERSION' => 'HTTP/1.1' }, {}],
      'other CGI variables' => [{ 'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/', 'rack.input' => 'x' }, {}],
      'an empty value' => [{ 'HTTP_X_API_KEY' => '' }, {}],
      'a non-String value' => [{ 'HTTP_X_COUNT' => 1 }, {}],
      'a non-Hash env' => [nil, {}]
    }.each do |label, (env, expected)|
      it "maps #{label}" do
        expect(described_class.headers_from_env(env)).to eq(expected)
      end
    end
  end
end
