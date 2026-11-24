# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe Emails do
    let(:batch_url) { 'https://us.posthog.com/api/messaging/send/email_batch/' }
    let(:status_by_key) { 'https://us.posthog.com/api/messaging/emails/status/?idempotency_key=' }
    let(:status_by_key_url) { %r{\Ahttps://us\.posthog\.com/api/messaging/emails/status/\?idempotency_key=} }
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

    describe '#batch' do
      it 'sends one request and returns a result per recipient, in order' do
        stub_request(:post, batch_url).to_return(answer(queued('msg_1'), queued('msg_2', replayed: true)))

        result = batch_template([ada, alan])

        expect(result.results.map(&:to_h)).to eq(
          [{ index: 0, to: 'ada@example.com', idempotency_key: 'welcome:ada', status: 'queued', message_id: 'msg_1',
             replayed: false, error: nil, later_error: nil },
           { index: 1, to: 'alan@example.com', idempotency_key: 'welcome:alan', status: 'queued',
             message_id: 'msg_2', replayed: true, error: nil, later_error: nil }]
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

      it 'splits more than 100 recipients into requests of at most 100, one after another' do
        recipients = Array.new(101) { |index| { to: "user#{index}@example.com", idempotency_key: "key-#{index}" } }
        stub_request(:post, batch_url).to_return(
          answer(*Array.new(100) { |index| queued("msg_#{index}") }), answer(queued('msg_100'))
        )

        result = batch_template(recipients)

        expect(batch_bodies.map { |body| body['recipients'].size }).to eq([100, 1])
        expect(result.results.map(&:message_id)).to eq(Array.new(101) { |index| "msg_#{index}" })
        expect(result.results.map(&:index)).to eq((0..100).to_a)
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

      it 'fails a recipient too large for one request and sends the rest' do
        stub_request(:post, batch_url).to_return(answer(queued('msg_2')))
        huge = { to: 'ada@example.com', template_data: { note: 'x' * (4 * 1024 * 1024) } }

        results = batch_template([huge, alan]).results

        expect(statuses(results)).to eq(%w[failed queued])
        expect([results.first.error.code, results.first.error.field]).to eq(%w[content_too_large recipients])
        expect(batch_bodies.map { |body| body['recipients'].map { |recipient| recipient['to'] } })
          .to eq([['alan@example.com']])
      end

      it 'fails every recipient when the shared content alone is too large, and sends nothing' do
        results = batch_template([ada, alan], template_data: { note: 'x' * (4 * 1024 * 1024) }).results

        expect(statuses(results)).to eq(%w[failed failed])
        expect(results.map { |result| result.error.code }.uniq).to eq(['content_too_large'])
        expect(results.first.error.fix).to eq("Make this recipient's template_data, or the batch's content, smaller.")
        expect(a_request(:any, %r{/api/messaging/})).not_to have_been_made
      end

      it 'sends a request of exactly 4 MiB and splits one a byte larger' do
        bodies = []
        stub_request(:post, batch_url).to_return do |request|
          bodies << request.body
          answer(*JSON.parse(request.body)['recipients'].map { |recipient| queued("msg_#{recipient['to']}") })
        end
        pair = lambda do |first, second|
          [{ to: 'ada@example.com', idempotency_key: 'k-ada', template_data: { note: 'x' * first } },
           { to: 'alan@example.com', idempotency_key: 'k-alan', template_data: { note: 'x' * second } }]
        end
        batch_template(pair.call(1, 1))
        fill = (4 * 1024 * 1024) - bodies.first.bytesize + 2

        batch_template(pair.call(fill / 2, fill - (fill / 2)))
        result = batch_template(pair.call(fill / 2, fill - (fill / 2) + 1))

        expect(bodies.drop(1).map(&:bytesize).first).to eq(4 * 1024 * 1024)
        expect(bodies.drop(1).map { |body| JSON.parse(body)['recipients'].size }).to eq([2, 1, 1])
        expect(bodies.last(2).map { |body| JSON.parse(body)['recipients'].first['message_data']['note'].size })
          .to eq([fill / 2, fill - (fill / 2) + 1])
        expect(statuses(result.results)).to eq(%w[queued queued])
      end

      it 'logs each warning once' do
        warning = { code: 'unverified_link', detail: 'A link points to an unverified domain.' }
        recipients = Array.new(101) { |index| { to: "user#{index}@example.com" } }
        stub_request(:post, batch_url).to_return(
          answer(*Array.new(100) { |index| queued("msg_#{index}") }, warnings: [warning]),
          answer(queued('msg_100'), warnings: [warning])
        )
        log = StringIO.new
        PostHog::Logging.logger = Logger.new(log)

        result = batch_template(recipients)

        expect(result.warnings.map(&:code)).to eq(['unverified_link'])
        expect(log.string.scan('PostHog email warning unverified_link').size).to eq(1)
      end

      it "lets the logger's error through, with a failed batch's error as its cause" do
        recipients = Array.new(101) { |index| { to: "user#{index}@example.com", idempotency_key: "key-#{index}" } }
        stub_request(:post, batch_url).to_return(
          answer(*Array.new(100) { |index| queued("msg_#{index}") }, warnings: [{ code: 'unverified_link' }]),
          refuse(409, 'batch_unavailable')
        )
        logger = Logger.new(File::NULL)
        allow(logger).to receive(:warn).and_raise(IOError, 'log device closed')
        PostHog::Logging.logger = logger

        expect { batch_template(recipients) }.to raise_error(IOError, 'log device closed') { |error|
          expect(error.cause).to be_a(EmailBatchError)
          expect(error.cause.results.map(&:status).tally).to eq('queued' => 100, 'failed' => 1)
        }
      end

      context 'when a request fails as a whole' do
        let(:recipients) do
          Array.new(201) do |index|
            { to: "user#{index}@example.com", idempotency_key: "key-#{index}" }
          end
        end

        it 'stops the batch and raises EmailBatchError with every recipient' do
          stub_request(:post, batch_url).to_return(
            answer(*Array.new(100) { |index| queued("msg_#{index}") }),
            refuse(400, 'invalid_recipient', detail: 'A recipient is invalid.', attr: 'recipients__7__to')
          )

          expect { batch_template(recipients) }.to raise_error(EmailBatchError) { |error|
            expect([error.code, error.status_code,
                    error.field]).to eq(['invalid_recipient', 400, 'recipients__107__to'])
            expect(error.results.size).to eq(201)
            expect(error.results.map(&:status).tally).to eq('queued' => 100, 'failed' => 100, 'not_attempted' => 1)
            expect(error.results[100].error.code).to eq('invalid_recipient')
            expect(error.results[200].error.code).to eq('not_attempted')
          }
          expect(a_request(:post, batch_url)).to have_been_made.twice
        end

        it 'raises batch_unavailable with the fix to send each email on its own' do
          stub_request(:post, batch_url).to_return(refuse(409, 'batch_unavailable', detail: 'Not yet.'))

          expect { batch_template([ada]) }.to raise_error(EmailBatchError) { |error|
            expect([error.code, error.status_code]).to eq(['batch_unavailable', 409])
            expect(error.fix).to include('send', 'idempotency_key')
            expect(error.results.map(&:status)).to eq(['failed'])
          }
        end

        it 'names a 404 as a missing template or batch sends that are off' do
          stub_request(:post, batch_url).to_return(status: 404, body: '')

          expect { batch_template([ada]) }.to raise_error(EmailBatchError) { |error|
            expect([error.code, error.name]).to eq(%w[not_found not_found])
            expect(error.why).to include("template doesn't exist")
          }
        end

        it 'keeps a recipient a lost answer may have queued unconfirmed, and reads its status by key' do
          stub_request(:post, batch_url).to_raise(Errno::ECONNRESET)
          stub_request(:get, "#{status_by_key}welcome%3Aada").to_return(status: 404, body: '{"code":"not_found"}')
          stub_request(:get, "#{status_by_key}welcome%3Aalan").to_return(
            status: 200, body: JSON.generate(id: 'msg_alan', status: 'queued', created_at: '2026-11-24T08:00:00Z',
                                             status_at: '2026-11-24T08:00:00Z')
          )

          expect { batch_template([ada, alan], max_retries: 1) }.to raise_error(EmailBatchError) { |error|
            expect(error.code).to eq('network_error')
            expect(error.results.map { |result| [result.status, result.message_id] })
              .to eq([['unconfirmed', nil], %w[queued msg_alan]])
            expect(error.results.first.error.code).to eq('delivery_unavailable')
          }
          expect(a_request(:post, batch_url)).to have_been_made.twice
          expect(a_request(:get, status_by_key_url)).to have_been_made.twice
        end

        it 'keeps a recipient whose status by key reads failed unconfirmed' do
          stub_request(:post, batch_url).to_raise(Errno::ECONNRESET)
          stub_request(:get, "#{status_by_key}welcome%3Aada").to_return(
            status: 200, body: JSON.generate(id: 'msg_ada', status: 'failed', reason: 'recipient_suppressed',
                                             created_at: '2026-11-24T08:00:00Z', status_at: '2026-11-24T08:00:00Z')
          )

          expect { batch_template([ada], max_retries: 0) }.to raise_error(EmailBatchError) { |error|
            result = error.results.first
            expect([result.status, result.message_id]).to eq(%w[unconfirmed msg_ada])
            expect([result.error.code, result.later_error.code]).to eq(%w[delivery_unavailable recipient_suppressed])
            expect(result.later_error.message_id).to be_nil
          }
        end

        it "keeps a retry's answer over a status by key that reads failed" do
          stub_request(:post, batch_url).to_return(refuse(503, 'delivery_unavailable'), refuse(429, 'rate_limited'))
          stub_request(:get, "#{status_by_key}welcome%3Aada").to_return(
            status: 200, body: JSON.generate(id: 'msg_ada', status: 'failed', reason: 'recipient_suppressed',
                                             created_at: '2026-11-24T08:00:00Z', status_at: '2026-11-24T08:00:00Z')
          )

          expect { batch_template([ada], max_retries: 1) }.to raise_error(EmailBatchError) { |error|
            result = error.results.first
            expect([result.status, result.message_id]).to eq(%w[unconfirmed msg_ada])
            expect([result.error.code, result.later_error.code]).to eq(%w[delivery_unavailable rate_limited])
          }
        end

        it 'keeps the first unconfirmed answer and adds what a later retry said' do
          stub_request(:post, batch_url).to_return(
            refuse(503, 'delivery_unavailable'),
            answer(slot_error('idempotency_key_reused', 422, message_id: 'msg_1'))
          )

          result = batch_template([ada])

          expect(result.results.first.to_h.slice(:status,
                                                 :message_id)).to eq(status: 'unconfirmed', message_id: 'msg_1')
          expect(result.results.first.error.code).to eq('delivery_unavailable')
          expect(result.results.first.later_error.code).to eq('idempotency_key_reused')
        end

        it "doesn't retry once the client shuts down" do
          stub_request(:post, batch_url).to_return do
            client.shutdown(timeout: 0)
            refuse(503, 'delivery_unavailable')
          end

          expect { batch_template([ada]) }.to raise_error(EmailBatchError) { |error|
            expect(error.code).to eq('client_closed')
            expect(statuses(error.results)).to eq(['unconfirmed'])
          }
          expect(a_request(:post, batch_url)).to have_been_made.once
        end

        it 'stops before the next request once the client shuts down' do
          recipients = Array.new(101) { |index| { to: "user#{index}@example.com" } }
          stub_request(:post, batch_url).to_return do
            client.shutdown(timeout: 0)
            answer(*Array.new(100) { |index| queued("msg_#{index}") })
          end

          expect { batch_template(recipients) }.to raise_error(EmailBatchError) { |error|
            expect(error.code).to eq('client_closed')
            expect(error.results.map(&:status).tally).to eq('queued' => 100, 'not_attempted' => 1)
          }
          expect(a_request(:post, batch_url)).to have_been_made.once
        end
      end

      it "waits at least 45 seconds for each answer, and connects and writes within the client's timeout" do
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
