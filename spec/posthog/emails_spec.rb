# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe Emails do
    let(:send_url) { 'https://us.posthog.com/api/projects/@current/messaging/send/email/' }
    let(:template_id) { '0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b' }
    let(:message_id) { '01a18356-c56c-0001-e494-7666bc915188' }
    let(:status_url) { "https://us.posthog.com/api/projects/@current/messaging/emails/#{message_id}/" }
    let(:uuid_v4) { /\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/ }
    let(:options) { { api_key: API_KEY, secret_key: ' phs_test ', test_mode: true } }
    let(:client) { Client.new(options) }
    let(:emails) { client.emails.tap { |emails| allow(emails).to receive(:sleep) { |seconds| delays << seconds } } }
    let(:delays) { [] }

    before do
      stub_request(:get, %r{/flags/definitions}).to_return(status: 200, body: '{"flags":[]}')
    end

    after { client.shutdown(timeout: 1) }

    def accept(message_id = 'msg_1', **extra)
      { status: 202, body: JSON.generate({ message_id: message_id }.merge(extra)) }
    end

    def refuse(status, code, detail: nil, headers: {}, **fields)
      { status: status, body: JSON.generate({ code: code, detail: detail }.merge(fields).compact), headers: headers }
    end

    def sent_bodies
      bodies = []
      expect(a_request(:post, send_url).with do |request|
        bodies << JSON.parse(request.body)
      end).to have_been_made.at_least_once
      bodies
    end

    # Serves each raw HTTP response once, in order, on a local socket, and points the client's app host at it. WebMock
    # is off meanwhile: its Net::HTTP wrapper reads the whole body before it hands over the response.
    def serve(*responses, tls: nil)
      server = TCPServer.new('127.0.0.1', 0)
      listener = tls ? OpenSSL::SSL::SSLServer.new(server, tls) : server
      responder = Thread.new do
        Thread.current.report_on_exception = false
        responses.each do |response|
          connection = listener.accept
          read_request(connection)
          connection.write(response)
          connection.close
        end
      end
      options.merge!(host: 'http://127.0.0.1:9', app_host: "#{tls ? 'https' : 'http'}://127.0.0.1:#{server.addr[1]}")
      WebMock.disable!
      yield
      expect(responder.join(5)).to be_truthy
    ensure
      WebMock.enable!
      server&.close
    end

    # Reads one whole request, so closing the connection never resets a client still writing its body.
    def read_request(connection)
      request = +''
      request << connection.readpartial(65_536) until request.include?("\r\n\r\n")
      head, body = request.split("\r\n\r\n", 2)
      length = head[/^content-length: *(\d+)/i, 1].to_i
      body << connection.readpartial(65_536) while body.bytesize < length
    end

    def http_response(status, body, headers = {})
      head = headers.merge('Content-Type' => 'application/json', 'Connection' => 'close')
      head['Content-Length'] ||= body.bytesize.to_s
      "HTTP/1.1 #{status}\r\n#{head.map { |name, value| "#{name}: #{value}\r\n" }.join}\r\n#{body}"
    end

    def self_signed_tls
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=127.0.0.1')
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      cert.sign(key, OpenSSL::Digest.new('SHA256'))
      OpenSSL::SSL::SSLContext.new.tap do |context|
        context.cert = cert
        context.key = key
      end
    end

    def send_template(**overrides)
      emails.send(to: 'user@example.com', template_id: template_id, **overrides)
    end

    def send_code(**overrides)
      emails.send(to: 'user@example.com', template_key: 'password-reset', subject: 'Reset your password',
                  html: '<p>Reset</p>', **overrides)
    end

    describe 'a send of a template made in PostHog' do
      it 'posts the template and its data to the app host with the secret key' do
        stub_request(:post, send_url).to_return(accept)

        result = send_template(template_id: template_id.upcase, template_data: { name: 'Ada' }, distinct_id: 'user_123')

        expect(result.id).to eq('msg_1')
        expect(result.replayed).to be(false)
        expect(
          a_request(:post, send_url).with(
            body: { template_id: template_id, message_data: { name: 'Ada' }, to: 'user@example.com',
                    distinct_id: 'user_123' },
            headers: {
              'Authorization' => 'Bearer phs_test',
              'Content-Type' => 'application/json',
              'Accept' => 'application/json',
              'User-Agent' => "posthog-ruby/#{PostHog::VERSION}"
            }
          )
        ).to have_been_made.once
      end

      it 'sends an empty message_data and no distinct_id when the caller passes neither' do
        stub_request(:post, send_url).to_return(accept)

        send_template

        expect(sent_bodies).to eq([{ 'template_id' => template_id, 'message_data' => {}, 'to' => 'user@example.com' }])
      end

      it 'sends dates in template_data as ISO 8601' do
        stub_request(:post, send_url).to_return(accept)

        send_template(template_data: { renews_at: Time.utc(2026, 11, 2, 9, 30) })

        expect(sent_bodies.first['message_data']).to eq('renews_at' => '2026-11-02T09:30:00.000Z')
      end

      it 'refuses code content, because the template sets its own' do
        expect { send_template(subject: 'Hi') }
          .to raise_error(ArgumentError, /template_id doesn't take subject.*send with template_key/)
        expect(a_request(:any, %r{/messaging/})).not_to have_been_made
      end
    end

    describe 'a send of content from your code' do
      it 'posts the content under its key and captures engagement by default' do
        stub_request(:post, send_url).to_return(accept)

        send_code(text: 'Reset', from: 'Acme <hello@example.com>', reply_to: 'help@example.com',
                  distinct_id: 'user_123')

        expect(sent_bodies).to eq([{
                                    'template_key' => 'password-reset',
                                    'subject' => 'Reset your password',
                                    'html' => '<p>Reset</p>',
                                    'text' => 'Reset',
                                    'from' => 'Acme <hello@example.com>',
                                    'reply_to' => ['help@example.com'],
                                    'capture_engagement' => true,
                                    'to' => 'user@example.com',
                                    'distinct_id' => 'user_123'
                                  }])
      end

      it 'turns engagement capture off when the caller asks' do
        stub_request(:post, send_url).to_return(accept)

        send_code(capture_engagement: false, reply_to: %w[a@example.com b@example.com])

        expect(sent_bodies.first).to include('capture_engagement' => false,
                                             'reply_to' => %w[a@example.com b@example.com])
      end

      it 'sends text alone' do
        stub_request(:post, send_url).to_return(accept)

        emails.send(to: 'user@example.com', template_key: 'digest', subject: 'Digest', text: 'Hello')

        expect(sent_bodies.first.keys).to contain_exactly('template_key', 'subject', 'text', 'capture_engagement', 'to')
      end

      it 'refuses template_data, because local templates are not supported' do
        expect { send_code(template_data: { name: 'Ada' }) }
          .to raise_error(ArgumentError, /template_key doesn't take template_data/)
      end

      it 'needs a subject and html or text' do
        expect { emails.send(to: 'user@example.com', template_key: 'k', html: '<p/>') }
          .to raise_error(ArgumentError, /needs a subject/)
        expect { emails.send(to: 'user@example.com', template_key: 'k', subject: 'Hi') }
          .to raise_error(ArgumentError, /needs html, text or both/)
      end

      it 'refuses a template_key with characters PostHog does not take' do
        expect { send_code(template_key: 'password reset') }.to raise_error(ArgumentError, /template_key can only/)
      end
    end

    describe 'copies and attachments' do
      let(:pdf) { "%PDF-1.7\n\xFF\x00\xE2".b }

      def refused_attachment(**overrides)
        send_code(**overrides)
      rescue EmailError => e
        e
      end

      it 'sends cc and bcc as lists' do
        stub_request(:post, send_url).to_return(accept)

        send_code(cc: 'finance@example.com', bcc: %w[audit@example.com archive@example.com])

        expect(sent_bodies.first).to include('cc' => ['finance@example.com'],
                                             'bcc' => %w[audit@example.com archive@example.com])
      end

      it 'sends the bytes of each file as Base64, with its type and content ID' do
        stub_request(:post, send_url).to_return(accept)

        send_code(attachments: [
                    { filename: 'invoice.pdf', content: pdf, content_type: 'application/pdf' },
                    { 'filename' => 'logo.png', 'content' => [137, 80, 78, 71], 'content_id' => 'logo' },
                    { filename: 'notes.txt', content: 'aGVsbG8=' }
                  ])

        expect(sent_bodies.first['attachments']).to eq([
                                                         { 'filename' => 'invoice.pdf',
                                                           'content' => 'JVBERi0xLjcK/wDi',
                                                           'content_type' => 'application/pdf' },
                                                         { 'filename' => 'logo.png', 'content' => 'iVBORw==',
                                                           'content_id' => 'logo' },
                                                         { 'filename' => 'notes.txt', 'content' => 'aGVsbG8=' }
                                                       ])
        expect(sent_bodies.first['attachments'][0]['content'].unpack1('m0')).to eq(pdf)
      end

      it 'leaves out empty lists, so a PostHog version without these fields still sends the email' do
        stub_request(:post, send_url).to_return(accept)

        send_code(cc: [], bcc: [], attachments: [])

        expect(sent_bodies.first.keys).not_to include('cc', 'bcc', 'attachments')
      end

      it 'sends the same encoded files on every attempt' do
        stub_request(:post, send_url).to_return(refuse(503, 'service_unavailable'), accept)

        send_code(attachments: [{ filename: 'invoice.pdf', content: pdf }])

        encoded_once = [{ 'filename' => 'invoice.pdf', 'content' => 'JVBERi0xLjcK/wDi' }]
        expect(a_request(:post, send_url).with { |request| JSON.parse(request.body)['attachments'] == encoded_once })
          .to have_been_made.twice
      end

      it 'takes Base64 with line breaks, as Base64.encode64 writes it' do
        stub_request(:post, send_url).to_return(accept)
        file = (0..99).to_a.pack('C*')

        send_code(attachments: [{ filename: 'data.bin', content: [file].pack('m') }])

        expect([file].pack('m')).to include("\n")
        expect(sent_bodies.first['attachments'][0]['content']).to eq([file].pack('m0'))
      end

      it 'refuses a file it cannot send before any request, naming the field and never the content' do
        cases = {
          { attachments: { filename: 'a.pdf', content: pdf } } => ['attachments', /list of files/],
          { attachments: ['a.pdf'] } => ['attachments__0', /Hash with filename and content/],
          { attachments: [{ filename: 'a.pdf', path: '/tmp/a.pdf' }] } => ['attachments__0__path', /File.binread/],
          { attachments: [{ filename: 'a.pdf', content: pdf, headers: {} }] } =>
            ['attachments__0__headers', /not headers/],
          { attachments: [{ filename: 'a.pdf' }] } => ['attachments__0__content', /needs content/],
          { attachments: [{ filename: 'a.pdf', content: [256] }] } => ['attachments__0__content', /needs content/],
          { attachments: [{ filename: 'a.pdf', content: 'secret text, not Base64' }] } =>
            ['attachments__0__content', /isn't Base64/],
          { attachments: [{ filename: 'a.pdf', content: "%PDF secret text \xE2\xE3".dup.force_encoding('UTF-8') }] } =>
            ['attachments__0__content', /isn't Base64/],
          { attachments: [{ filename: 'codes.txt', content: "ABCD1234\nEFGH5678\n" }] } =>
            ['attachments__0__content', /isn't Base64/],
          { attachments: [{ filename: 'a.txt', content: 'aGVsbG8='.encode('UTF-16LE') }] } =>
            ['attachments__0__content', /isn't Base64/],
          { attachments: [{ filename: :a, content: pdf }] } => ['attachments__0__filename', /filename/],
          { attachments: [{ filename: 'a.pdf', content: pdf, content_type: 1 }] } =>
            ['attachments__0__content_type', /content_type/]
        }

        cases.each do |arguments, (field, message)|
          error = refused_attachment(**arguments)
          expect(error).to be_a(EmailError), "#{arguments} raised #{error.inspect}"
          expect([error.code, error.name, error.field]).to eq(['invalid_attachment', 'validation_error', field])
          expect(error.message).to match(message)
          expect(error.message).not_to include('secret text')
        end
        expect(a_request(:any, %r{/messaging/})).not_to have_been_made
      end

      it 'refuses an address list that is not one', :aggregate_failures do
        expect { send_code(cc: [nil]) }.to raise_error(ArgumentError, /cc must be one address or a list/)
        expect { send_code(bcc: 3) }.to raise_error(ArgumentError, /bcc must be one address or a list/)
      end

      it 'refuses them on a template send, because the template sets its own recipients and files' do
        %i[cc bcc attachments].each do |field|
          expect { send_template(field => []) }
            .to raise_error(ArgumentError, /template_id doesn't take #{field}.*send with template_key/)
        end
        expect(a_request(:any, %r{/messaging/})).not_to have_been_made
      end
    end

    describe 'argument checks' do
      it 'needs exactly one form' do
        expect { emails.send(to: 'user@example.com') }.to raise_error(ArgumentError, /either template_id, or/)
        expect { send_code(template_id: template_id) }.to raise_error(ArgumentError, /either template_id, or/)
      end

      it 'refuses bad arguments before any request' do
        expect { send_template(template_id: 'welcome') }.to raise_error(ArgumentError, /template's UUID/)
        expect { send_template(to: ' ') }.to raise_error(ArgumentError, /to must be/)
        expect { send_template(distinct_id: '') }.to raise_error(ArgumentError, /distinct_id/)
        expect { send_template(idempotency_key: 'has space') }.to raise_error(ArgumentError, /idempotency_key/)
        expect { send_template(max_retries: -1) }.to raise_error(ArgumentError, /max_retries/)
        expect { send_template(template_data: []) }.to raise_error(ArgumentError, /template_data must be a Hash/)
        expect { send_code(capture_engagement: 'no') }.to raise_error(ArgumentError, /capture_engagement/)
        expect { send_code(reply_to: [1]) }.to raise_error(ArgumentError, /reply_to/)
        expect { send_template(headers: {}) }.to raise_error(ArgumentError, /unknown keyword: :headers/)
        expect(a_request(:any, %r{/messaging/})).not_to have_been_made
      end
    end

    describe 'integration marker' do
      before { stub_request(:post, send_url).to_return(refuse(503, 'delivery_unavailable'), accept) }

      it 'names the integration that made the send on every attempt, and keeps the User-Agent' do
        send_code(integration: 'action-mailer/3.14.0')

        expect(a_request(:post, send_url).with(
                 headers: { 'X-PostHog-Integration' => 'action-mailer/3.14.0',
                            'User-Agent' => "posthog-ruby/#{PostHog::VERSION}" }
               )).to have_been_made.twice
      end

      it 'sends no marker without the option' do
        send_template

        expect(a_request(:post, send_url).with { |request| request.headers.key?('X-Posthog-Integration') })
          .not_to have_been_made
      end

      it 'refuses a marker outside name/version before any request' do
        ['action-mailer', 'Action-Mailer/1.0', 'action mailer/1.0', 'action-mailer/1.0 beta', "#{'a' * 41}/1.0", 7]
          .each do |integration|
            expect { send_code(integration: integration) }.to raise_error(ArgumentError, /integration must be/)
          end
        expect(a_request(:any, %r{/messaging/})).not_to have_been_made
      end
    end

    describe 'client setup' do
      it 'maps an EU ingestion host to the EU app host' do
        options[:host] = 'https://eu.i.posthog.com/'
        stub_request(:post, 'https://eu.posthog.com/api/projects/@current/messaging/send/email/').to_return(accept)

        expect(send_template.id).to eq('msg_1')
      end

      it 'refuses a custom host without app_host, so a proxy never receives the secret key' do
        options[:host] = 'https://proxy.example.com'

        expect { send_template }.to raise_error(EmailError) { |error|
          expect(error.code).to eq('missing_app_host')
          expect(error.name).to eq('application_error')
        }
        expect(a_request(:any, %r{/messaging/})).not_to have_been_made
      end

      it 'sends to app_host when the client sets it' do
        options.merge!(host: 'https://proxy.example.com', app_host: 'https://posthog.example.com/')
        stub_request(:post, 'https://posthog.example.com/api/projects/@current/messaging/send/email/').to_return(accept)

        expect(send_template.id).to eq('msg_1')
      end

      it 'refuses a send without a secret key' do
        options.delete(:secret_key)

        expect { send_template }.to raise_error(EmailError) { |error|
          expect(error.code).to eq('missing_secret_key')
          expect(error.name).to eq('missing_api_key')
        }
        expect(a_request(:any, %r{/messaging/})).not_to have_been_made
      end

      it 'sends nothing from a disabled client' do
        options[:api_key] = nil

        expect { send_template }.to raise_error(EmailError) { |error| expect(error.code).to eq('client_disabled') }
        expect(a_request(:any, %r{/messaging/})).not_to have_been_made
      end

      it 'names the provider the app moved from on every request' do
        options[:migrated_from] = 'resend'
        stub_request(:post, send_url).to_return(accept)

        send_template

        expect(a_request(:post, send_url).with(headers: { 'X-PostHog-Migrated-From' => 'resend' })).to have_been_made
      end

      it 'refuses email options it cannot use' do
        expect { Client.new(options.merge(email_request_max_retries: -1)) }.to raise_error(ArgumentError, /max_retries/)
        expect { Client.new(options.merge(email_request_timeout_seconds: 0)) }.to raise_error(ArgumentError, /timeout/)
        expect do
          Client.new(options.merge(migrated_from: 'my provider'))
        end.to raise_error(ArgumentError, /migrated_from/)
        %w[posthog.example.com ftp://posthog.example.com https://].each do |app_host|
          expect { Client.new(options.merge(app_host: app_host)) }.to raise_error(ArgumentError, /app_host/)
        end
      end

      it 'refuses a bad email option before it polls flags with the secret key' do
        expect do
          Client.new(options.merge(test_mode: false, email_request_timeout_seconds: 0))
        end.to raise_error(ArgumentError, /timeout/)
        expect(a_request(:get, %r{/flags/definitions})).not_to have_been_made
      end

      it 'uses the defaults for email options passed as nil' do
        stub_request(:post, send_url).to_return(refuse(503, 'delivery_unavailable'), refuse(503, 'x'), accept)
        options.merge!(email_request_timeout_seconds: nil, email_request_max_retries: nil)

        expect(send_template.id).to eq('msg_1')
      end

      it 'skips certificate checks when the client sets skip_ssl_verification' do
        options[:skip_ssl_verification] = true

        serve(http_response('202 Accepted', JSON.generate(message_id: 'msg_1')), tls: self_signed_tls) do
          expect(send_template.id).to eq('msg_1')
        end
      end
    end

    describe 'retries' do
      it 'retries an unavailable service with the same generated idempotency key' do
        stub_request(:post, send_url).to_return(refuse(503, 'delivery_unavailable'), accept)

        expect(send_template.id).to eq('msg_1')

        keys = []
        expect(a_request(:post, send_url).with { |request| keys << request.headers['Idempotency-Key'] })
          .to have_been_made.twice
        expect(keys.uniq.size).to eq(1)
        expect(keys.first).to match(uuid_v4)
        expect(delays.first).to be_between(0.8, 1.2)
      end

      it 'keeps the caller idempotency key' do
        stub_request(:post, send_url).to_return(accept)

        send_template(idempotency_key: 'welcome:user_123')

        expect(a_request(:post, send_url).with(headers: { 'Idempotency-Key' => 'welcome:user_123' })).to have_been_made
      end

      it 'makes 3 attempts by default and reports the last error' do
        stub_request(:post, send_url).to_return(refuse(503, 'delivery_unavailable', detail: 'Try later.'))

        expect { send_template }.to raise_error(EmailError, 'Try later.') { |error|
          expect(error.name).to eq('service_unavailable')
          expect(error.status_code).to eq(503)
        }
        expect(a_request(:post, send_url)).to have_been_made.times(3)
        expect(delays.size).to eq(2)
      end

      it 'makes 1 attempt when the send turns retries off' do
        stub_request(:post, send_url).to_return(refuse(503, 'delivery_unavailable'))

        expect { send_template(max_retries: 0) }.to raise_error(EmailError)
        expect(a_request(:post, send_url)).to have_been_made.once
      end

      it 'uses the client retry limit' do
        options[:email_request_max_retries] = 0
        stub_request(:post, send_url).to_return(refuse(503, 'delivery_unavailable'))

        expect { send_template }.to raise_error(EmailError)
        expect(a_request(:post, send_url)).to have_been_made.once
      end

      [
        [503, 'delivery_unavailable', 2],
        [429, 'throttled', 2],
        [409, 'idempotency_key_in_flight', 2],
        [429, 'quota_limited', 1],
        [422, 'recipient_suppressed', 1]
      ].each do |status, code, attempts|
        it "makes #{attempts} attempts for a #{status} #{code}" do
          stub_request(:post, send_url).to_return(refuse(status, code), accept)

          begin
            send_template
          rescue EmailError
            nil
          end
          expect(a_request(:post, send_url)).to have_been_made.times(attempts)
        end
      end

      it 'retries a network error, and reports it as service_unavailable' do
        stub_request(:post, send_url).to_raise(Errno::ECONNREFUSED)

        expect { send_template }.to raise_error(EmailError) { |error|
          expect(error.code).to eq('network_error')
          expect(error.name).to eq('service_unavailable')
          expect(error.cause).to be_a(Errno::ECONNREFUSED)
        }
        expect(a_request(:post, send_url)).to have_been_made.times(3)
      end

      it 'retries a timeout' do
        stub_request(:post, send_url).to_timeout.then.to_return(accept)

        expect(send_template.id).to eq('msg_1')
      end

      it 'retries an acceptance whose body was cut off' do
        cut_off = http_response('202 Accepted', '{"message_id":"msg', 'Content-Length' => '22')

        serve(cut_off, http_response('202 Accepted', JSON.generate(message_id: 'msg_1'))) do
          expect(send_template.id).to eq('msg_1')
        end
      end

      it 'retries an acceptance whose compressed body is corrupt' do
        # A gzip header, then a deflate block of a type that does not exist.
        corrupt = http_response('202 Accepted', "\x1F\x8B\x08\x00\x00\x00\x00\x00\x00\x03\xFF\xFF".b,
                                'Content-Encoding' => 'gzip')

        serve(corrupt, http_response('202 Accepted', JSON.generate(message_id: 'msg_1'))) do
          expect(send_template.id).to eq('msg_1')
        end
      end

      it 'retries a refusal whose body was cut off, as a network error' do
        cut_off = http_response('409 Conflict', '{"code":"idempotency_key_in', 'Content-Length' => '60')

        serve(cut_off, http_response('202 Accepted', JSON.generate(message_id: 'msg_1'))) do
          expect(send_template.id).to eq('msg_1')
        end
      end

      it 'keeps the Retry-After of a refusal whose body was cut off' do
        cut_off = http_response('429 Too Many Requests', '{"code":"thro',
                                'Content-Length' => '40', 'Retry-After' => '60')

        serve(cut_off) do
          expect { send_template }.to raise_error(EmailError) { |error|
            expect([error.code, error.retry_after]).to eq(['network_error', 60.0])
          }
        end
      end

      it 'waits out the Retry-After of a cut-off refusal before it retries' do
        cut_off = http_response('503 Service Unavailable', '{"code":"deliv',
                                'Content-Length' => '40', 'Retry-After' => '3')
        serve(cut_off, http_response('202 Accepted', JSON.generate(message_id: 'msg_1'))) do
          emails
          expect(send_template.id).to eq('msg_1')
        end
        expect(delays).to eq([3.0])
      end

      it 'waits for a longer Retry-After' do
        stub_request(:post, send_url).to_return(refuse(429, 'throttled', headers: { 'Retry-After' => '5' }), accept)

        send_template

        expect(delays).to eq([5.0])
      end

      it 'fails at once on a Retry-After over 30 seconds' do
        stub_request(:post, send_url).to_return(refuse(429, 'throttled', headers: { 'Retry-After' => '60' }))

        expect { send_template }.to raise_error(EmailError) { |error|
          expect(error.code).to eq('throttled')
          expect(error.retry_after).to eq(60.0)
        }
        expect(a_request(:post, send_url)).to have_been_made.once
      end

      it 'does not retry an acceptance without a message ID' do
        stub_request(:post, send_url).to_return(status: 202, body: '{}')

        expect { send_template }.to raise_error(EmailError) { |error|
          expect(error.code).to eq('api_error')
          expect(error.status_code).to eq(202)
        }
        expect(a_request(:post, send_url)).to have_been_made.once
      end
    end

    describe 'results and errors' do
      it 'returns a replay and logs each warning' do
        stub_request(:post, send_url).to_return(
          accept('msg_1', replayed: true, warnings: [{ code: 'unverified_link', detail: 'Check links.', fix: 'Fix.' }])
        )
        log = StringIO.new
        PostHog::Logging.logger = Logger.new(log, level: Logger::WARN)

        result = send_template

        expect(log.string).to include('PostHog email warning unverified_link: Check links.')

        expect(result.replayed).to be(true)
        expect(result.warnings).to eq([Emails::Warning.new(code: 'unverified_link', message: 'Check links.',
                                                           fix: 'Fix.')])
      end

      it "keeps PostHog's error fields" do
        stub_request(:post, send_url).to_return(
          refuse(400, 'sender_not_verified', detail: 'Verify it.', attr: 'from', why: 'Unverified.',
                                             fix: 'Verify the domain.', docs_url: 'https://posthog.com/docs/x')
        )

        expect { send_code }.to raise_error(EmailError, 'Verify it.') { |error|
          expect([error.code, error.name, error.status_code]).to eq(['sender_not_verified', 'validation_error', 400])
          expect([error.field, error.why, error.fix, error.docs_url])
            .to eq(['from', 'Unverified.', 'Verify the domain.', 'https://posthog.com/docs/x'])
        }
      end

      it 'reports an answer without a code as api_error with the name of its status' do
        stub_request(:post, send_url).to_return(status: 403, body: '<html>Forbidden</html>')

        expect { send_template }.to raise_error(EmailError, 'PostHog answered HTTP 403.') { |error|
          expect([error.code, error.name]).to eq(%w[api_error invalid_permission])
        }
      end

      [
        [401, 'authentication_failed', 'missing_api_key'],
        [404, 'not_found', 'not_found'],
        [409, 'template_outdated', 'validation_error'],
        [409, 'idempotency_key_in_flight', 'concurrent_idempotent_requests'],
        [422, 'idempotency_key_reused', 'invalid_idempotent_request'],
        [422, 'recipient_suppressed', 'validation_error'],
        [429, 'quota_limited', 'monthly_quota_exceeded'],
        [429, 'throttled', 'rate_limit_exceeded'],
        [500, 'server_error', 'application_error']
      ].each do |status, code, name|
        it "names a #{status} #{code} #{name}" do
          stub_request(:post, send_url).to_return(refuse(status, code))

          expect { send_template(max_retries: 0) }.to raise_error(EmailError) { |error|
            expect([error.code, error.name, error.status_code]).to eq([code, name, status])
          }
        end
      end
    end

    describe '#get' do
      let(:record) do
        { id: message_id, status: 'bounced', created_at: '2026-10-28T16:27:44.364000Z',
          status_at: '2026-10-28T16:30:02.100000Z', reason: 'hard' }
      end

      it "reads the email's status" do
        stub_request(:get, status_url).to_return(status: 200, body: JSON.generate(record))

        status = emails.get(message_id.upcase)

        expect(status.to_h).to eq(
          id: message_id, status: 'bounced', reason: 'hard',
          created_at: Time.utc(2026, 10, 28, 16, 27, 44.364r), status_at: Time.utc(2026, 10, 28, 16, 30, 2.1r)
        )
        expect(a_request(:get,
                         status_url).with(headers: { 'Authorization' => 'Bearer phs_test' })).to have_been_made.once
      end

      it 'passes a status it does not know through' do
        stub_request(:get, status_url).to_return(status: 200,
                                                 body: JSON.generate(record.merge(
                                                                       status: 'archived', reason: nil
                                                                     )))

        expect(emails.get(message_id)).to have_attributes(status: 'archived', reason: nil)
      end

      it 'does not retry an unknown message ID' do
        stub_request(:get, status_url).to_return(refuse(404, 'not_found'))

        expect { emails.get(message_id) }.to raise_error(EmailError) { |error| expect(error.code).to eq('not_found') }
        expect(a_request(:get, status_url)).to have_been_made.once
      end

      it 'reports a record without its times as api_error' do
        stub_request(:get, status_url).to_return(status: 200, body: JSON.generate(record.merge(status_at: 'soon')))

        expect { emails.get(message_id) }.to raise_error(EmailError) { |error| expect(error.code).to eq('api_error') }
      end

      it 'refuses an ID that is not a message ID' do
        expect { emails.get('msg_1') }.to raise_error(ArgumentError, /message_id/)
      end
    end

    describe 'shutdown' do
      it 'refuses sends after the client shuts down' do
        client.shutdown

        expect { send_template }.to raise_error(EmailError) { |error| expect(error.code).to eq('client_closed') }
        expect(a_request(:any, %r{/messaging/})).not_to have_been_made
      end

      it 'does not wait in a forked child for a send that runs in the parent', skip: !Process.respond_to?(:fork) do
        request_started = Queue.new
        release = Queue.new
        stub_request(:post, send_url).to_return do
          request_started << true
          release.pop
          accept
        end
        sender = Thread.new { send_template }
        request_started.pop

        child = fork { exit!(client.shutdown(timeout: 5) ? 0 : 1) }
        _, status = Process.wait2(child)
        release << true

        expect(status.exitstatus).to eq(0)
        expect(sender.value.id).to eq('msg_1')
      end

      context 'with a send in its retry backoff' do
        let(:backoff_started) { Queue.new }
        let(:release_retry) { Queue.new }

        before do
          allow(emails).to receive(:sleep) do |_seconds|
            backoff_started << true
            release_retry.pop
          end
          stub_request(:post, send_url).to_return(refuse(503, 'delivery_unavailable'), accept)
        end

        it 'waits for the retry to settle' do
          sender = Thread.new { send_template }
          backoff_started.pop
          shutdown = Thread.new { client.shutdown(timeout: 5) }

          expect(shutdown.join(0.2)).to be_nil
          release_retry << true

          expect(shutdown.value).to be(true)
          expect(a_request(:post, send_url)).to have_been_made.twice
          expect(sender.value.id).to eq('msg_1')
        end

        it 'keeps to its timeout' do
          sender = Thread.new { send_template }
          backoff_started.pop

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          expect(client.shutdown(timeout: 0.05)).to be(false)
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.25
          release_retry << true
          sender.join
        end
      end
    end
  end
end
