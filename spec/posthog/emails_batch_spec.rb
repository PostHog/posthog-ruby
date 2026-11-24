# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe Emails do
    let(:batch_url) { 'https://us.posthog.com/api/messaging/send/email_batch/' }
    let(:template_id) { '0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b' }
    let(:uuid_v4) { /\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/ }
    let(:options) { { api_key: API_KEY, secret_key: 'phs_test', test_mode: true } }
    let(:client) { Client.new(options) }
    let(:emails) { client.emails.tap { |emails| allow(emails).to receive(:sleep) { |seconds| delays << seconds } } }
    let(:delays) { [] }
    let(:ada) { { to: 'ada@example.com', idempotency_key: 'welcome:ada', template_data: { name: 'Ada' } } }
    let(:alan) { { to: 'alan@example.com', distinct_id: 'user_2', idempotency_key: 'welcome:alan' } }

    before do
      stub_request(:get, %r{/flags/definitions}).to_return(status: 200, body: '{"flags":[]}')
    end

    after { client.shutdown(timeout: 1) }

    def queued(message_id, replayed: false)
      { message_id: message_id, status: 'queued', replayed: replayed }
    end

    def slot_error(code, status, message_id: 'msg_x')
      { message_id: message_id, error: { code: code, detail: "PostHog didn't queue it: #{code}.", status: status } }
    end

    def answer(*slots, warnings: nil)
      { status: 200, body: JSON.generate({ results: slots, warnings: warnings }.compact) }
    end

    def refuse(status, code, **fields)
      { status: status, body: JSON.generate({ code: code }.merge(fields)) }
    end

    def batch_bodies
      bodies = []
      expect(a_request(:post, batch_url).with { |request| bodies << JSON.parse(request.body) })
        .to have_been_made.at_least_once
      bodies
    end

    def batch_template(recipients, **extra)
      emails.batch(template_id: template_id, template_data: { product: 'Hog' }, recipients: recipients, **extra)
    end

    def statuses(results)
      results.map(&:status)
    end

    def resend_with_key(result)
      [result.status, result.idempotency_key,
       result.error.fix.to_s.include?('same idempotency_key within 24 hours of the first request that used it')]
    end
    describe '#batch' do
      it 'sends one request and returns a result per recipient, in order' do
        stub_request(:post, batch_url).to_return(answer(queued('msg_1'), queued('msg_2', replayed: true)))

        result = batch_template([ada, alan])

        expect(result.results.map(&:to_h)).to eq(
          [{ index: 0, to: 'ada@example.com', idempotency_key: 'welcome:ada', status: 'queued', message_id: 'msg_1',
             replayed: false, error: nil },
           { index: 1, to: 'alan@example.com', idempotency_key: 'welcome:alan', status: 'queued',
             message_id: 'msg_2', replayed: true, error: nil }]
        )
        expect(batch_bodies).to eq(
          [{ 'template_id' => template_id, 'message_data' => { 'product' => 'Hog' },
             'recipients' => [
               { 'to' => 'ada@example.com', 'idempotency_key' => 'welcome:ada', 'message_data' => { 'name' => 'Ada' } },
               { 'to' => 'alan@example.com', 'idempotency_key' => 'welcome:alan', 'distinct_id' => 'user_2' }
             ] }]
        )
        expect(a_request(:post, batch_url).with(headers: { 'Authorization' => 'Bearer phs_test' })).to have_been_made
      end

      it 'makes a key for each recipient without one, and keeps it on every retry' do
        stub_request(:post, batch_url).to_return(refuse(503, 'delivery_unavailable'),
                                                 answer(queued('msg_1'), queued('msg_2')))

        result = batch_template([{ to: 'ada@example.com' }, { 'to' => 'alan@example.com' }])

        keys = result.results.map(&:idempotency_key)
        expect(keys).to all(match(uuid_v4))
        expect(keys.uniq.size).to eq(2)
        expect(a_request(:post, batch_url)).to have_been_made.twice
        # WebMock records identical requests once, so one body means both attempts sent the same keys.
        expect(batch_bodies.map { |body| body['recipients'].map { |recipient| recipient['idempotency_key'] } })
          .to eq([keys])
        expect(statuses(result.results)).to eq(%w[queued queued])
      end

      it 'sends the code form with the same content for every recipient' do
        stub_request(:post, batch_url).to_return(answer(queued('msg_1')))

        emails.batch(template_key: 'launch-news', subject: 'We launched', html: '<p>Hi</p>', from: 'a@example.com',
                     recipients: [{ to: 'ada@example.com', idempotency_key: 'launch:ada' }])

        expect(batch_bodies.first).to eq(
          'template_key' => 'launch-news', 'subject' => 'We launched', 'html' => '<p>Hi</p>',
          'from' => 'a@example.com',
          'recipients' => [{ 'to' => 'ada@example.com', 'idempotency_key' => 'launch:ada' }]
        )
      end

      it 'sends 100 recipients in one request, and refuses 101 before any request' do
        hundred = Array.new(100) { |index| { to: "user#{index}@example.com", idempotency_key: "key-#{index}" } }
        stub_request(:post, batch_url).to_return(answer(*Array.new(100) { |index| queued("msg_#{index}") }))

        expect { batch_template(hundred + [{ to: 'user100@example.com' }]) }
          .to raise_error(ArgumentError, /at most 100 recipients/)
        expect(a_request(:post, batch_url)).not_to have_been_made

        result = batch_template(hundred)

        expect(batch_bodies.map { |body| body['recipients'].size }).to eq([100])
        expect(result.results.map(&:message_id)).to eq(Array.new(100) { |index| "msg_#{index}" })
      end

      it "returns each recipient PostHog refused as failed and one it didn't confirm as unconfirmed" do
        stub_request(:post, batch_url).to_return(
          answer(slot_error('recipient_suppressed', 422, message_id: 'msg_1'),
                 slot_error('delivery_unavailable', 503, message_id: 'msg_2'), 'not a result')
        )

        results = batch_template([ada, alan, { to: 'grace@example.com' }]).results

        expect(statuses(results)).to eq(%w[failed unconfirmed unconfirmed])
        expect(results.map { |result| [result.message_id, result.error.code, result.error.name] }).to eq(
          [%w[msg_1 recipient_suppressed validation_error], %w[msg_2 delivery_unavailable service_unavailable],
           [nil, 'api_error', 'application_error']]
        )
        expect(results.first.error.status_code).to eq(422)
        expect(results.map { |result| result.error.message_id }).to eq([nil, 'msg_2', nil])
      end

      it 'keeps a recipient the retry refused unconfirmed when a lost answer may have queued it' do
        stub_request(:post, batch_url).to_raise(Errno::ECONNRESET).then.to_return(
          answer(queued('msg_ada'), slot_error('recipient_suppressed', 422, message_id: nil))
        )

        results = batch_template([ada, alan], max_retries: 1).results

        expect(results.map(&:status)).to eq(%w[queued unconfirmed])
        expect([results.last.error.code, resend_with_key(results.last)])
          .to eq(['recipient_suppressed', ['unconfirmed', 'welcome:alan', true]])
        expect(results.last.error.message).to start_with('An earlier attempt of this batch may have queued')
      end

      it 'leaves an unconfirmed email PostHog answered without an ID to be sent again with its key' do
        stub_request(:post, batch_url).to_return(
          answer(slot_error('delivery_unavailable', 503, message_id: 'msg_ada'),
                 slot_error('delivery_unavailable', 503, message_id: nil), { status: 'queued' })
        )

        results = batch_template([ada, alan, { to: 'grace@example.com', idempotency_key: 'welcome:grace' }]).results

        expect(results.map(&:message_id)).to eq(['msg_ada', nil, nil])
        expect(results.map { |result| resend_with_key(result) }).to eq(
          [['unconfirmed', 'welcome:ada', true], ['unconfirmed', 'welcome:alan', true],
           ['unconfirmed', 'welcome:grace', true]]
        )
        expect(a_request(:get, %r{/api/messaging/emails/status/})).not_to have_been_made
      end

      it "logs the reply's warnings once each" do
        warning = { code: 'unverified_link', detail: 'A link points to an unverified domain.' }
        stub_request(:post, batch_url).to_return(answer(queued('msg_1'), warnings: [warning, warning]))
        log = StringIO.new
        PostHog::Logging.logger = Logger.new(log, level: Logger::WARN)

        result = batch_template([ada])

        expect(result.warnings.map(&:code)).to eq(['unverified_link'])
        expect(log.string.scan('PostHog email warning unverified_link').size).to eq(1)
      end

      it "carries a failed batch's warnings on its error and never logs them" do
        stub_request(:post, batch_url).to_return(answer(warnings: [{ code: 'unverified_link' }]))
        log = StringIO.new
        PostHog::Logging.logger = Logger.new(log, level: Logger::WARN)

        expect { batch_template([ada]) }.to raise_error(EmailBatchError) { |error|
          expect([error.code, error.cause, error.warnings.map(&:code)]).to eq(['api_error', nil, ['unverified_link']])
        }
        expect(log.string).to be_empty
      end

      it 'lets a failing logger stop a batch that succeeded with its own error' do
        stub_request(:post, batch_url).to_return(answer(queued('msg_0'), warnings: [{ code: 'unverified_link' }]))
        PostHog::Logging.logger = Logger.new(StringIO.new, level: Logger::WARN,
                                                           formatter: ->(*) { raise IOError, 'log device closed' })

        expect { batch_template([{ to: 'user@example.com' }]) }.to raise_error(IOError, 'log device closed') { |error|
          expect(error.cause).to be_nil
        }
      end

      context 'when the request fails as a whole' do
        it 'raises EmailBatchError with every recipient failed and the field PostHog named' do
          stub_request(:post, batch_url).to_return(
            refuse(400, 'invalid_recipient', detail: 'A recipient is invalid.', attr: 'recipients__1__to')
          )

          expect { batch_template([ada, alan]) }.to raise_error(EmailBatchError) { |error|
            expect([error.code, error.status_code, error.field]).to eq(['invalid_recipient', 400, 'recipients__1__to'])
            expect(error.results.map { |result| [result.status, result.error.code] })
              .to eq([%w[failed invalid_recipient], %w[failed invalid_recipient]])
          }
          expect(a_request(:post, batch_url)).to have_been_made.once
        end

        {
          'a 413 with its code and fix' => [
            { status: 413, body: JSON.generate(code: 'content_too_large', detail: 'Too large.', fix: 'Split them.') },
            'Split them.'
          ],
          'a 413 without a JSON body' => [{ status: 413, body: '<html>Request Entity Too Large</html>' }, 'smaller'],
          'a 413 with an empty code and fix' => [{ status: 413, body: JSON.generate(code: '', fix: '') }, 'smaller'],
          'a 413 with fields that are not text' => [
            { status: 413, body: JSON.generate(code: 413, fix: false) }, 'smaller'
          ]
        }.each do |name, (reply, fix)|
          it "surfaces #{name} as content_too_large, with PostHog's fix or the advice to split the recipients" do
            stub_request(:post, batch_url).to_return(reply)

            expect { batch_template([ada, alan]) }.to raise_error(EmailBatchError) { |error|
              expect([error.code, error.status_code]).to eq(['content_too_large', 413])
              expect(error.fix).to include(fix)
              expect(statuses(error.results)).to eq(%w[failed failed])
            }
            expect(a_request(:post, batch_url)).to have_been_made.once
          end
        end

        it "keeps a 400 content_too_large for content over PostHog's limit as PostHog sent it, without split advice" do
          stub_request(:post, batch_url).to_return(
            refuse(400, 'content_too_large', fix: 'Make template_data smaller.', attr: 'template_data')
          )

          expect { batch_template([ada]) }.to raise_error(EmailBatchError) { |error|
            expect([error.code, error.status_code, error.fix])
              .to eq(['content_too_large', 400, 'Make template_data smaller.'])
            expect(statuses(error.results)).to eq(%w[failed])
          }
        end

        it 'raises batch_unavailable with the fix to send each email on its own' do
          stub_request(:post, batch_url).to_return(refuse(409, 'batch_unavailable', detail: 'Not yet.'))

          expect { batch_template([ada]) }.to raise_error(EmailBatchError) { |error|
            expect([error.code, error.name, error.status_code]).to eq(['batch_unavailable', 'validation_error', 409])
            expect(error.fix).to include('send', 'idempotency_key')
            expect(error.results.map(&:status)).to eq(['failed'])
          }
          expect(a_request(:post, batch_url)).to have_been_made.once
        end

        ['', 'Wait a few seconds and try again.'].each do |fix|
          it "keeps every recipient unconfirmed while PostHog holds the keys, with fix #{fix.inspect}" do
            stub_request(:post, batch_url).to_return(refuse(409, 'idempotency_key_in_flight', fix: fix))

            expect { batch_template([ada, alan], max_retries: 0) }.to raise_error(EmailBatchError) { |error|
              expect([error.code, error.results.map(&:message_id)]).to eq(['idempotency_key_in_flight', [nil, nil]])
              expect(error.results.map { |result| resend_with_key(result) })
                .to eq([['unconfirmed', 'welcome:ada', true], ['unconfirmed', 'welcome:alan', true]])
            }
            expect(a_request(:post, batch_url)).to have_been_made.once
          end
        end

        it 'names a 404 as a missing template or batch sends that are off' do
          stub_request(:post, batch_url).to_return(status: 404, body: '')

          expect { batch_template([ada]) }.to raise_error(EmailBatchError) { |error|
            expect([error.code, error.name]).to eq(%w[not_found not_found])
            expect(error.why).to include("template doesn't exist")
          }
        end

        it 'keeps the recipients a lost answer may have queued unconfirmed, to send again with their keys' do
          stub_request(:post, batch_url).to_raise(Errno::ECONNRESET)

          expect { batch_template([ada, alan], max_retries: 1) }.to raise_error(EmailBatchError) { |error|
            expect(error.code).to eq('network_error')
            expect(error.results.map { |result| [result.message_id, result.error.code] })
              .to eq([[nil, 'network_error'], [nil, 'network_error']])
            expect(error.results.map { |result| resend_with_key(result) })
              .to eq([['unconfirmed', 'welcome:ada', true], ['unconfirmed', 'welcome:alan', true]])
          }
          expect(a_request(:post, batch_url)).to have_been_made.twice
          expect(a_request(:get, %r{/api/messaging/emails/status/})).not_to have_been_made
        end

        it 'keeps the recipients a lost answer may have queued unconfirmed when the retry is refused' do
          stub_request(:post, batch_url).to_raise(Errno::ECONNRESET).then.to_return(refuse(429, 'rate_limited'))

          expect { batch_template([ada, alan], max_retries: 1) }.to raise_error(EmailBatchError) { |error|
            expect(error.code).to eq('rate_limited')
            expect(error.results.first.error.message).to start_with('An earlier attempt of this batch may have queued')
            expect(error.results.map { |result| resend_with_key(result) })
              .to eq([['unconfirmed', 'welcome:ada', true], ['unconfirmed', 'welcome:alan', true]])
          }
          expect(a_request(:post, batch_url)).to have_been_made.twice
        end

        it 'keeps every recipient unconfirmed when the answer has no result for each, and never retries it' do
          stub_request(:post, batch_url).to_return(answer(queued('msg_1')))

          expect { batch_template([ada, alan]) }.to raise_error(EmailBatchError) { |error|
            expect(error.code).to eq('api_error')
            expect(error.results.map { |result| resend_with_key(result) })
              .to eq([['unconfirmed', 'welcome:ada', true], ['unconfirmed', 'welcome:alan', true]])
          }
          expect(a_request(:post, batch_url)).to have_been_made.once
        end

        {
          [503, 503] => %w[unconfirmed delivery_unavailable],
          [503, 400] => %w[unconfirmed invalid_recipient],
          [503, 429] => %w[unconfirmed rate_limited],
          [429, 400] => %w[failed invalid_recipient]
        }.each do |statuses, (status, code)|
          it "reports the last attempt's error after #{statuses.join(', ')}, unconfirmed if one may have queued" do
            codes = { 400 => 'invalid_recipient', 429 => 'rate_limited', 503 => 'delivery_unavailable' }
            stub_request(:post, batch_url).to_return(*statuses.map { |answered| refuse(answered, codes[answered]) })

            expect { batch_template([ada], max_retries: 1) }.to raise_error(EmailBatchError) { |error|
              result = error.results.first
              expect([error.code, result.status, result.error.code]).to eq([code, status, code])
            }
            expect(a_request(:post, batch_url)).to have_been_made.twice
          end
        end

        {
          'a 502 without a code' => [{ status: 502, body: '<html>Bad gateway</html>' }, 'unconfirmed'],
          'a 504 with a code' => [{ status: 504, body: JSON.generate(code: 'gateway_timeout') }, 'unconfirmed'],
          'a 403 without a code' => [{ status: 403, body: '<html>Forbidden</html>' }, 'failed'],
          'a 403 naming keys in flight' => [
            { status: 403, body: JSON.generate(code: 'idempotency_key_in_flight') }, 'failed'
          ]
        }.each do |name, (reply, status)|
          it "leaves every recipient #{status} after #{name}, the status deciding whether it may have gone out" do
            stub_request(:post, batch_url).to_return(reply)

            expect { batch_template([ada], max_retries: 0) }.to raise_error(EmailBatchError) { |error|
              expect(error.status_code).to eq(reply[:status])
              expect(resend_with_key(error.results.first)).to eq([status, 'welcome:ada', status == 'unconfirmed'])
            }
          end
        end

        it 'leaves the recipients failed when the client shuts down after PostHog refused the only request' do
          stub_request(:post, batch_url).to_return do
            client.shutdown(timeout: 0)
            refuse(429, 'rate_limited')
          end

          expect { batch_template([ada], max_retries: 1) }.to raise_error(EmailBatchError) { |error|
            expect([error.code, error.results.map(&:status)]).to eq(['client_closed', ['failed']])
          }
          expect(a_request(:post, batch_url)).to have_been_made.once
        end

        it "doesn't retry once the client shuts down, and leaves the recipients unconfirmed" do
          stub_request(:post, batch_url).to_return do
            client.shutdown(timeout: 0)
            refuse(503, 'delivery_unavailable')
          end

          expect { batch_template([ada]) }.to raise_error(EmailBatchError) { |error|
            expect(error.code).to eq('client_closed')
            expect(resend_with_key(error.results.first)).to eq(['unconfirmed', 'welcome:ada', true])
          }
          expect(a_request(:post, batch_url)).to have_been_made.once
        end
      end

      it "hands Net::HTTP a read wait of at least 45 seconds and the client's connect and write timeouts" do
        stub_request(:post, batch_url).to_return(answer(queued('msg_1')))
        allow(Net::HTTP).to receive(:start).and_call_original
        options[:email_request_timeout_seconds] = 3

        batch_template([ada])

        expect(Net::HTTP).to have_received(:start)
          .with('us.posthog.com', 443, hash_including(read_timeout: 45.0, open_timeout: 3, write_timeout: 3))
      end

      it 'refuses a bad batch before any request' do
        [
          [{ recipients: [] }, /at least one recipient/],
          [{ recipients: ada }, /recipients must be an Array/],
          [{ recipients: [ada, ada.merge(to: 'b@example.com')] },
           /recipients\[1\] has the same idempotency_key as recipients\[0\]/],
          [{ recipients: [{ to: '' }] }, /recipients\[0\]: to must be/],
          [{ recipients: [{ to: 'a@example.com', cc: 'b@example.com' }] }, /recipients\[0\] takes only/],
          [{ recipients: [ada], scheduled_at: Time.now }, /unknown keyword: :scheduled_at/],
          [{ recipients: [ada], cc: 'b@example.com' }, /unknown keyword: :cc/],
          [{ recipients: [ada], template_id: 'nope' }, /template_id must be/]
        ].each do |args, message|
          expect { emails.batch(template_id: template_id, **args) }.to raise_error(ArgumentError, message)
        end
        expect do
          emails.batch(template_key: 'launch', subject: 'Hi', text: 'Hi', recipients: [ada])
        end.to raise_error(ArgumentError, /recipients\[0\] has template_data/)
        expect(a_request(:any, %r{/api/messaging/})).not_to have_been_made
      end
    end
  end
end
