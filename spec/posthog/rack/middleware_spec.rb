# frozen_string_literal: true

require 'spec_helper'

begin
  require 'rack/test'
rescue LoadError
  # Skip these tests if rack-test is not available
  puts "Skipping Rack middleware tests (rack-test not available)"
  return
end

module PostHog
  module Rack
    describe Middleware do
      include ::Rack::Test::Methods

      let(:app) { double('app') }
      let(:middleware) { Middleware.new(app) }
      let(:env) { {} }
      
      before do
        PostHog.reset!
        PostHog.configure do |config|
          config.api_key = 'test_key'
          config.test_mode = true
          config.auto_capture_exceptions = true
        end
      end

      after { PostHog.reset! }

      describe '#call' do
        context 'when no exception occurs' do
          it 'calls the app normally' do
            expect(app).to receive(:call).with(env).and_return([200, {}, ['OK']])
            result = middleware.call(env)
            expect(result).to eq([200, {}, ['OK']])
          end
        end

        context 'when exception occurs' do
          let(:exception) { StandardError.new('Test error') }

          before do
            allow(app).to receive(:call).with(env).and_raise(exception)
          end

          it 'captures exception and re-raises it' do
            expect(PostHog).to receive(:capture_exception).with(
              exception,
              hash_including(
                distinct_id: kind_of(String),
                tags: hash_including(source: 'rack_middleware'),
                extra: hash_including(:request, :environment),
                handled: false
              )
            )

            expect { middleware.call(env) }.to raise_error(StandardError, 'Test error')
          end

          it 'extracts request data from env' do
            env.merge!({
              'REQUEST_METHOD' => 'POST',
              'PATH_INFO' => '/api/test',
              'QUERY_STRING' => 'param=value',
              'HTTP_USER_AGENT' => 'Test Agent',
              'REMOTE_ADDR' => '127.0.0.1'
            })

            expect(PostHog).to receive(:capture_exception) do |_, attrs|
              request_data = attrs[:extra][:request]
              expect(request_data[:method]).to eq('POST')
              expect(request_data[:path]).to eq('/api/test')
              expect(request_data[:query_string]).to eq('param=value')
              expect(request_data[:user_agent]).to eq('Test Agent')
              expect(request_data[:remote_ip]).to eq('127.0.0.1')
            end

            expect { middleware.call(env) }.to raise_error(StandardError)
          end

          it 'filters sensitive parameters' do
            # Mock Rack::Request to return params with sensitive data
            request_double = double('request')
            allow(::Rack::Request).to receive(:new).and_return(request_double)
            allow(request_double).to receive(:request_method).and_return('POST')
            allow(request_double).to receive(:url).and_return('http://test.com')
            allow(request_double).to receive(:path).and_return('/test')
            allow(request_double).to receive(:query_string).and_return('')
            allow(request_double).to receive(:user_agent).and_return('Test')
            allow(request_double).to receive(:ip).and_return('127.0.0.1')
            allow(request_double).to receive(:content_type).and_return('application/json')
            allow(request_double).to receive(:content_length).and_return(100)
            allow(request_double).to receive(:params).and_return({
              'username' => 'test_user',
              'password' => 'secret123',
              'api_key' => 'sensitive_key'
            })

            expect(PostHog).to receive(:capture_exception) do |_, attrs|
              params = attrs[:extra][:request][:params]
              expect(params['username']).to eq('test_user')
              expect(params['password']).to eq('[FILTERED]')
              expect(params['api_key']).to eq('[FILTERED]')
            end

            expect { middleware.call(env) }.to raise_error(StandardError)
          end

          context 'when auto_capture_exceptions is disabled' do
            before do
              PostHog.configuration.auto_capture_exceptions = false
            end

            it 'does not capture exception' do
              expect(PostHog).not_to receive(:capture_exception)
              expect { middleware.call(env) }.to raise_error(StandardError)
            end
          end

          context 'when exception is ignored' do
            before do
              PostHog.configuration.ignored_exceptions = ['StandardError']
            end

            it 'does not capture ignored exception' do
              expect(PostHog).not_to receive(:capture_exception)
              expect { middleware.call(env) }.to raise_error(StandardError)
            end
          end

          context 'when exception class is ignored' do
            before do
              PostHog.configuration.ignored_exceptions = [StandardError]
            end

            it 'does not capture ignored exception class' do
              expect(PostHog).not_to receive(:capture_exception)
              expect { middleware.call(env) }.to raise_error(StandardError)
            end
          end

          context 'when exception matches regex pattern' do
            before do
              PostHog.configuration.ignored_exceptions = [/Standard/]
            end

            it 'does not capture exception matching regex' do
              expect(PostHog).not_to receive(:capture_exception)
              expect { middleware.call(env) }.to raise_error(StandardError)
            end
          end
        end

        context 'when PostHog is not configured' do
          before do
            PostHog.configuration.api_key = nil
          end

          it 'does not capture exception when not configured' do
            allow(app).to receive(:call).with(env).and_raise(StandardError.new('Test'))
            
            expect(PostHog).not_to receive(:capture_exception)
            expect { middleware.call(env) }.to raise_error(StandardError)
          end
        end

        context 'distinct_id extraction' do
          let(:exception) { StandardError.new('Test error') }

          before do
            allow(app).to receive(:call).and_raise(exception)
          end

          it 'extracts distinct_id from session' do
            env['rack.session'] = { 'posthog_user_id' => 'session_user_123' }

            expect(PostHog).to receive(:capture_exception) do |_, attrs|
              expect(attrs[:distinct_id]).to eq('session_user_123')
            end

            expect { middleware.call(env) }.to raise_error(StandardError)
          end

          it 'extracts distinct_id from cookies' do
            env['HTTP_COOKIE'] = 'posthog_user_id=cookie_user_456; other=value'

            expect(PostHog).to receive(:capture_exception) do |_, attrs|
              expect(attrs[:distinct_id]).to eq('cookie_user_456')
            end

            expect { middleware.call(env) }.to raise_error(StandardError)
          end

          it 'falls back to IP address' do
            env['REMOTE_ADDR'] = '192.168.1.100'

            expect(PostHog).to receive(:capture_exception) do |_, attrs|
              expect(attrs[:distinct_id]).to eq('192.168.1.100')
            end

            expect { middleware.call(env) }.to raise_error(StandardError)
          end

          it 'uses forwarded IP when available' do
            env['HTTP_X_FORWARDED_FOR'] = '10.0.0.1, 192.168.1.1'
            env['REMOTE_ADDR'] = '127.0.0.1'

            expect(PostHog).to receive(:capture_exception) do |_, attrs|
              expect(attrs[:distinct_id]).to eq('10.0.0.1')
            end

            expect { middleware.call(env) }.to raise_error(StandardError)
          end
        end

        context 'when exception capture fails' do
          let(:exception) { StandardError.new('Original error') }

          before do
            allow(app).to receive(:call).and_raise(exception)
            allow(PostHog).to receive(:capture_exception).and_raise('Capture failed')
          end

          it 'warns but still raises original exception' do
            expect { middleware.call(env) }.to raise_error(StandardError, 'Original error')
          end
        end
      end
    end
  end
end