# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe Transport do
    before do
      # Try and keep debug statements out of tests
      allow(subject.logger).to receive(:error)
      allow(subject.logger).to receive(:debug)
      allow(subject.logger).to receive(:warn)
    end

    describe '#initialize' do
      let!(:net_http) { Net::HTTP.new(anything, anything) }

      before { allow(Net::HTTP).to receive(:new) { net_http } }

      it 'sets an initalized Net::HTTP read_timeout' do
        expect(net_http).to receive(:use_ssl=)
        described_class.new
      end

      it 'sets an initalized Net::HTTP read_timeout' do
        expect(net_http).to receive(:read_timeout=)
        described_class.new
      end

      it 'sets an initalized Net::HTTP open_timeout' do
        expect(net_http).to receive(:open_timeout=)
        described_class.new
      end

      it 'sets the http client' do
        expect(subject.instance_variable_get(:@http)).to_not be_nil
      end

      context 'no options are set' do
        it 'sets a default path' do
          path = subject.instance_variable_get(:@path)
          expect(path).to eq(described_class::PATH)
        end

        it 'sets a default retries' do
          retries = subject.instance_variable_get(:@retries)
          expect(retries).to eq(described_class::RETRIES)
        end

        it 'sets a default backoff policy' do
          backoff_policy = subject.instance_variable_get(:@backoff_policy)
          expect(backoff_policy).to be_a(PostHog::BackoffPolicy)
        end

        it 'compresses requests by default' do
          compress_request = subject.instance_variable_get(:@compress_request)
          expect(compress_request).to eq(true)
        end

        it 'uses the default verify mode' do
          expect(net_http).to_not receive(:verify_mode=)
          described_class.new
        end

        it 'initializes a new Net::HTTP with default host and port' do
          expect(Net::HTTP).to receive(:new).with(
            described_class::HOST,
            described_class::PORT
          )
          described_class.new
        end
      end

      context 'options are given' do
        let(:path) { 'my/cool/path' }
        let(:retries) { 1234 }
        let(:backoff_policy) { FakeBackoffPolicy.new([1, 2, 3]) }
        let(:skip_ssl_verification) { true }
        let(:compress_request) { false }
        let(:host) { 'http://www.example.com' }
        let(:port) { 8080 }
        let(:options) do
          {
            path: path,
            retries: retries,
            backoff_policy: backoff_policy,
            skip_ssl_verification: skip_ssl_verification,
            compress_request: compress_request,
            host: host,
            port: port
          }
        end

        subject { described_class.new(options) }

        it 'sets passed in path' do
          expect(subject.instance_variable_get(:@path)).to eq(path)
        end

        it 'sets passed in retries' do
          expect(subject.instance_variable_get(:@retries)).to eq(retries)
        end

        it 'sets passed in backoff backoff policy' do
          expect(subject.instance_variable_get(:@backoff_policy)).to eq(
            backoff_policy
          )
        end

        it 'sets passed in compression option' do
          expect(subject.instance_variable_get(:@compress_request)).to eq(false)
        end

        it 'skips SSL verification if passed' do
          expect(net_http).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_NONE)
          described_class.new(options)
        end

        it 'initializes a new Net::HTTP with passed in host and port' do
          expect(Net::HTTP).to receive(:new).with(host, port)
          described_class.new(options)
        end
      end
    end

    describe '#shutdown' do
      it 'is idempotent' do
        http = subject.instance_variable_get(:@http)
        allow(http).to receive(:started?).and_return(true, false)
        expect(http).to receive(:finish).once

        2.times { subject.shutdown }
      end
    end

    describe '#send' do
      let(:response) do
        Net::HTTPResponse.new(http_version, status_code, response_body)
      end
      let(:http_version) { 1.1 }
      let(:status_code) { 200 }
      let(:response_body) { {}.to_json }
      let(:api_key) { 'abcdefg' }
      let(:batch) { [] }

      before do
        http = subject.instance_variable_get(:@http)
        allow(http).to receive(:start)
        allow(http).to receive(:request) { response }
        allow(response).to receive(:body) { response_body }
      end

      it 'initalizes a new Net::HTTP::Post with path and gzip header by default' do
        path = subject.instance_variable_get(:@path)
        default_headers = {
          'Content-Type' => 'application/json',
          'Accept' => 'application/json',
          'User-Agent' => "posthog-ruby/#{PostHog::VERSION}",
          'Content-Encoding' => 'gzip'
        }
        expect(Net::HTTP::Post).to receive(:new)
          .with(path, default_headers)
          .and_call_original

        subject.send(api_key, batch)
      end

      context 'with a stub' do
        before { allow(described_class).to receive(:stub) { true } }

        it 'returns a 200 response' do
          expect(subject.send(api_key, batch).status).to eq(200)
        end

        it 'has a nil error' do
          expect(subject.send(api_key, batch).error).to be_nil
        end

        it 'logs a debug statement' do
          expect(subject.logger).to receive(:debug).with(/stubbed request to/)
          subject.send(api_key, batch)
        end
      end

      context 'a real request' do
        RSpec.shared_examples('retried request') do |status_code, body|
          let(:status_code) { status_code }
          let(:body) { body }
          let(:retries) { 4 }
          let(:backoff_policy) { FakeBackoffPolicy.new([1000, 1000, 1000]) }
          subject do
            described_class.new(
              retries: retries,
              backoff_policy: backoff_policy
            )
          end

          it 'retries the request' do
            expect(subject).to receive(:sleep)
              .exactly(retries - 1)
              .times
              .with(1)
              .and_return(nil)
            subject.send(api_key, batch)
          end
        end

        RSpec.shared_examples('non-retried request') do |status_code, body|
          let(:status_code) { status_code }
          let(:body) { body }
          let(:retries) { 4 }
          let(:backoff) { 1 }
          subject { described_class.new(retries: retries, backoff: backoff) }

          it 'does not retry the request' do
            expect(subject).to receive(:sleep).never
            subject.send(api_key, batch)
          end
        end

        context 'request is successful' do
          let(:status_code) { 201 }
          it 'returns a response code' do
            expect(subject.send(api_key, batch).status).to eq(status_code)
          end

          it 'returns a nil error' do
            expect(subject.send(api_key, batch).error).to be_nil
          end
        end

        context 'with default compression' do
          let(:batch) { [{ event: 'compression-test' }] }
          let(:raw_payload) { JSON.generate(api_key: api_key, batch: batch) }

          it 'gzips the request body and sets the content encoding header' do
            http = subject.instance_variable_get(:@http)
            expect(http).to receive(:request) do |request, payload|
              expect(request.path).to eq('/batch/')
              expect(request['Content-Encoding']).to eq('gzip')
              expect(Zlib.gunzip(payload)).to eq(raw_payload)
              response
            end

            subject.send(api_key, batch)
          end

          it 'falls back to the original body when gzip compression fails' do
            allow(Zlib).to receive(:gzip).and_raise(Zlib::Error.new('boom'))
            expect(subject.logger).to receive(:warn).with('gzip compression failed; sending uncompressed - boom')

            http = subject.instance_variable_get(:@http)
            expect(http).to receive(:request) do |request, payload|
              expect(request.path).to eq('/batch/')
              expect(request['Content-Encoding']).to be_nil
              expect(payload).to eq(raw_payload)
              response
            end

            subject.send(api_key, batch)
          end

          it 'does not fall back for non-zlib errors' do
            allow(Zlib).to receive(:gzip).and_raise(TypeError, 'bad payload')
            subject.instance_variable_set(:@retries, 1)

            http = subject.instance_variable_get(:@http)
            expect(http).not_to receive(:request)

            res = subject.send(api_key, batch)
            expect(res.status).to eq(-1)
            expect(res.error).to include('bad payload')
          end
        end

        context 'with compression disabled' do
          subject { described_class.new(compress_request: false) }

          let(:batch) { [{ event: 'compression-test' }] }
          let(:raw_payload) { JSON.generate(api_key: api_key, batch: batch) }

          it 'sends the original body without the content encoding header' do
            http = subject.instance_variable_get(:@http)
            expect(http).to receive(:request) do |request, payload|
              expect(request.path).to eq('/batch/')
              expect(request['Content-Encoding']).to be_nil
              expect(payload).to eq(raw_payload)
              response
            end

            subject.send(api_key, batch)
          end
        end

        context 'request results in errorful response' do
          let(:error) { 'this is an error' }
          let(:response_body) { { error: error }.to_json }

          it 'returns the parsed error' do
            expect(subject.send(api_key, batch).error).to eq(error)
          end
        end

        context 'a request returns a failure status code' do
          # Server errors must be retried
          it_behaves_like('retried request', 500, '{}')
          it_behaves_like('retried request', 503, '{}')

          # All 4xx errors other than 429 (rate limited) must be retried
          it_behaves_like('retried request', 429, '{}')
          it_behaves_like('non-retried request', 404, '{}')
          it_behaves_like('non-retried request', 400, '{}')
        end

        context 'a retryable response includes Retry-After' do
          let(:status_code) { 429 }
          let(:retries) { 2 }
          let(:backoff_policy) { FakeBackoffPolicy.new([1000]) }

          subject do
            described_class.new(
              retries: retries,
              backoff_policy: backoff_policy
            )
          end

          it 'honors Retry-After: 0 as an immediate retry' do
            allow(response).to receive(:[]).with('Retry-After').and_return('0')
            expect(subject).to receive(:sleep).once.with(0.0).and_return(nil)

            subject.send(api_key, batch)
          end

          it 'does not reuse a stale Retry-After header after retries are exhausted' do
            http = subject.instance_variable_get(:@http)
            rate_limited_response = Net::HTTPResponse.new(http_version, 429, 'Too Many Requests')
            allow(rate_limited_response).to receive(:body).and_return(response_body)
            allow(rate_limited_response).to receive(:[]).with('Retry-After').and_return('123')

            success_response = Net::HTTPResponse.new(http_version, 200, 'OK')
            allow(success_response).to receive(:body).and_return(response_body)
            allow(success_response).to receive(:[]).with('Retry-After').and_return(nil)

            requests = [rate_limited_response, IOError.new('connection reset'), success_response]
            allow(http).to receive(:request) do
              next_request = requests.shift
              raise next_request if next_request.is_a?(StandardError)

              next_request
            end

            subject.instance_variable_set(:@retries, 1)
            subject.send(api_key, batch)

            subject.instance_variable_set(:@retries, 2)
            expect(subject).to receive(:sleep).once.with(1).and_return(nil)
            subject.send(api_key, batch)
          end
        end

        context 'response body is malformed JSON' do
          let(:response_body) { 'Malformed JSON ---' }

          subject { described_class.new(retries: 0) }

          it 'returns the HTTP status code' do
            expect(subject.send(api_key, batch).status).to eq(200)
          end

          it 'uses the raw body as the error' do
            error = subject.send(api_key, batch).error
            expect(error).to eq('Malformed JSON ---')
          end

          it_behaves_like('non-retried request', 200, 'Malformed JSON ---')
        end
      end
    end
  end
end
