# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require 'logger'
require 'rails'
require 'action_mailer'
require 'active_job'
$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)
require 'posthog/rails'

require 'posthog/rails/delivery_method'

# What the Railtie's Action Mailer load hook does, done once on Action Mailer itself. Registering the hook here would
# run it on the stand-in classes other specs pass to run_load_hooks. 'a Rails app' below boots the Railtie's own hook.
ActionMailer::Base.prepend PostHog::Rails::MailerExtensions
ActionMailer::Base.add_delivery_method :posthog, PostHog::Rails::DeliveryMethod

class ShippingMailer < ActionMailer::Base
  self.delivery_method = :posthog
  self.posthog_settings = { default_template_key: 'transactional' }

  def shipped(headers = {})
    attachments['invoice.pdf'] = "%PDF-1.4\n"
    addresses = { from: 'Shop <shop@example.com>', to: 'Ana <ana@example.com>' }
    mail(**addresses, subject: 'Your order shipped', **headers) do |format|
      format.text { render plain: 'On its way.' }
      format.html { render html: '<p>On its way.</p>'.html_safe }
    end
  end
end

module Admin
  class UserMailer < ActionMailer::Base
    self.delivery_method = :posthog

    def welcome_email
      mail(from: 'shop@example.com', to: 'ana@example.com', subject: 'Welcome') do |format|
        format.text { render plain: 'Hi' }
      end
    end
  end
end

RSpec.describe PostHog::Rails::DeliveryMethod do
  let(:send_url) { 'https://us.posthog.com/api/projects/@current/messaging/send/email/' }
  let(:message_id) { '01a18356-c56c-0001-e494-7666bc915188' }
  let(:settings) { {} }
  let(:stored) { {} }
  let(:shipped_body) do
    { 'to' => 'ana@example.com', 'from' => 'Shop <shop@example.com>', 'subject' => 'Your order shipped',
      'html' => '<p>On its way.</p>', 'text' => 'On its way.', 'template_key' => 'action-mailer' }
  end

  before do
    PostHog::Logging.logger = Logger.new(File::NULL)
    stub_request(:get, %r{/flags/definitions}).to_return(status: 200, body: '{"flags":[]}')
    stub_request(:post, send_url).to_return(status: 202, body: JSON.generate(message_id: message_id))
    stub_request(:post, 'https://us.posthog.com/api/projects/@current/messaging/attachments/uploads/')
      .to_return { |request| upload_slots(JSON.parse(request.body)['files']) }
    stub_request(:put, %r{\Ahttps://files\.example\.com/team/\h{64}\?}).to_return do |request|
      stored[request.uri.path[/\h{64}\z/]] = request.body.b
      { status: 200 }
    end
    PostHog.init(api_key: API_KEY, secret_key: 'phs_test', test_mode: true, email_request_max_retries: 0)
  end

  after do
    PostHog.client&.shutdown
    PostHog.client = nil
  end

  # The message of conformance case 01: one recipient, a From display name, and HTML and text bodies.
  def shipped_mail
    Mail.new do
      from 'Shop <shop@example.com>'
      to 'Ana <ana@example.com>'
      subject 'Your order shipped'
      text_part { body 'On its way.' }
      html_part { body '<p>On its way.</p>' }
    end
  end

  def text_only_mail
    Mail.new do
      from 'Shop <shop@example.com>'
      to 'ana@example.com'
      subject 'Your order shipped'
      content_type 'multipart/mixed'
      text_part { body 'On its way.' }
    end
  end

  def deliver(mail)
    mail.delivery_method(described_class, settings)
    mail.deliver
  end

  def sent_request
    requests = []
    expect(a_request(:post, send_url).with { |request| requests << request }).to have_been_made.once
    requests.first
  end

  def sent_body
    JSON.parse(sent_request.body)
  end

  # PostHog's upload route: file storage takes every file of the manifest.
  def upload_slots(files)
    slots = files.map do |file|
      { sha256: file['sha256'], status: 'upload', method: 'PUT', headers: {},
        url: "https://files.example.com/team/#{file['sha256']}?X-Amz-Signature=fake",
        url_expires_at: '2026-11-13T12:15:00Z' }
    end
    { status: 200, body: JSON.generate(files: slots) }
  end

  # The files PostHog attaches to the sent email: each one the send names, with the bytes file storage holds for it.
  def sent_files
    sent_body.fetch('attachments').map do |file|
      file.except('sha256').merge('content' => stored.fetch(file['sha256']))
    end
  end

  def refusal_of(mail)
    refusal = nil
    expect { deliver(mail) }.to raise_error(PostHog::Rails::UnsupportedMailError) { |error| refusal = error.refusal }
    expect(a_request(:post, send_url)).not_to have_been_made
    refusal
  end

  describe 'conformance cases' do
    it '01 sends a rendered message with the integration marker, and takes its message ID' do
      mail = deliver(shipped_mail)

      expect(sent_body).to eq(shipped_body)
      expect(sent_request.headers['X-Posthog-Integration']).to eq("action-mailer/#{PostHog::Rails::VERSION}")
      expect(mail.message_id).to eq(message_id)
    end

    it '01 keeps the quotes a From display name needs' do
      mail = shipped_mail
      mail.from = '"Doe, Jane" <jane@example.com>'

      deliver(mail)

      expect(sent_body['from']).to eq('"Doe, Jane" <jane@example.com>')
    end

    it '02 and 03 drop recipient display names and send cc, bcc and reply-to as lists' do
      mail = shipped_mail
      mail.cc = 'Bo <bo@example.com>'
      mail.bcc = 'audit@example.com'
      mail.reply_to = ['Help <a@example.com>', 'b@example.com']

      deliver(mail)

      expect(sent_body).to eq(shipped_body.merge('cc' => ['bo@example.com'], 'bcc' => ['audit@example.com'],
                                                 'reply_to' => ['a@example.com', 'b@example.com']))
    end

    it '04 sends attachments, and an inline one with its content ID' do
      mail = shipped_mail
      mail.html_part.body = '<img src="cid:logo">'
      mail.attachments['invoice.pdf'] = "%PDF-1.4\n"
      mail.attachments.inline['logo.png'] = "\x89PNG\r\n\x1A\n".b
      mail.attachments['logo.png'].content_id = '<logo>'

      deliver(mail)

      expect(sent_body.except('attachments')).to eq(shipped_body.merge('html' => '<img src="cid:logo">'))
      expect(sent_files).to eq([
                                 { 'filename' => 'invoice.pdf', 'content_type' => 'application/pdf',
                                   'content' => "%PDF-1.4\n" },
                                 { 'filename' => 'logo.png', 'content_type' => 'image/png',
                                   'content' => "\x89PNG\r\n\x1A\n".b, 'content_id' => 'logo' }
                               ])
    end

    it '05 reads the PostHog options from the reserved headers and sends none of them' do
      mail = shipped_mail
      mail['X-PostHog-Distinct-Id'] = 'user_42'
      mail['X-PostHog-Template-Key'] = 'order-shipped'
      mail['X-PostHog-Idempotency-Key'] = 'order-981-shipped'
      mail['X-PostHog-Capture-Engagement'] = 'false'

      deliver(mail)

      expect(sent_body).to eq(shipped_body.merge('template_key' => 'order-shipped', 'distinct_id' => 'user_42',
                                                 'capture_engagement' => false))
      expect(sent_request.headers['Idempotency-Key']).to eq('order-981-shipped')
      expect(sent_request.headers.keys.grep(/distinct|template|engagement/i)).to be_empty
    end

    it '06 names mail from its mailer and action, made safe for a template key' do
      Admin::UserMailer.welcome_email.deliver_now

      expect(sent_body['template_key']).to eq('admin-user_mailer-welcome_email')
    end

    it '07 falls back to the default template key from posthog_settings' do
      settings[:default_template_key] = 'transactional'

      deliver(shipped_mail)

      expect(sent_body['template_key']).to eq('transactional')
    end

    it '08 refuses an explicit template key PostHog does not accept' do
      mail = shipped_mail
      mail['X-PostHog-Template-Key'] = 'order shipped!'

      expect(refusal_of(mail)).to eq('invalid_template_key')
    end

    it 'sends an explicit template key of 256 characters and refuses a longer one' do
      longest = shipped_mail
      longest['X-PostHog-Template-Key'] = 'k' * 256
      too_long = shipped_mail
      too_long['X-PostHog-Template-Key'] = 'k' * 257

      expect(refusal_of(too_long)).to eq('invalid_template_key')
      deliver(longest)

      expect(sent_body['template_key']).to eq('k' * 256)
    end

    it 'cuts a derived template key to the 256 characters PostHog accepts' do
      mailer = Class.new(Admin::UserMailer) { self.mailer_name = 'm' * 300 }

      mailer.welcome_email.deliver_now

      expect(sent_body['template_key']).to eq('m' * 256)
    end

    it '09 refuses more than one To address' do
      mail = shipped_mail
      mail.to = ['ana@example.com', 'bo@example.com']

      expect(refusal_of(mail)).to eq('multiple_to')
    end

    it '10 refuses an inline attachment without a content ID' do
      mail = shipped_mail
      mail.attachments.inline['logo.png'] = "\x89PNG\r\n\x1A\n".b

      expect(refusal_of(mail)).to eq('inline_without_cid')
    end

    it '11 ignores the headers Mail writes itself and refuses any other' do
      mail = shipped_mail
      mail.message_id = '<x@example.com>'
      mail['X-Campaign'] = 'spring'

      expect(refusal_of(mail)).to eq('unsupported_header')
    end

    it '13 refuses an envelope sender other than From' do
      mail = shipped_mail
      mail.smtp_envelope_from = 'bounce@example.com'

      expect(refusal_of(mail)).to eq('envelope_mismatch')
    end

    it '16 refuses a template made in PostHog, since Action Mailer sends rendered mail' do
      mail = shipped_mail
      mail['X-PostHog-Template-Id'] = '0190f0c2-7d1e-7a3b-9c2e-5f1a2b3c4d5e'

      expect(refusal_of(mail)).to eq('template_unsupported')
    end
  end

  describe 'other refusals' do
    it 'refuses a body part PostHog cannot send, such as a calendar invite' do
      mail = shipped_mail
      mail.add_part(Mail::Part.new(content_type: 'text/calendar; method=REQUEST', body: 'BEGIN:VCALENDAR'))

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    it 'refuses a signed message, whose signature a rebuilt message would break' do
      mail = shipped_mail
      mail.content_type = 'multipart/signed; protocol="application/pkcs7-signature"; micalg=sha-256'
      mail.add_file(filename: 'smime.p7s', content: 'signature')

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    it 'refuses an attachment that is itself a multipart message' do
      mail = shipped_mail
      forwarded = Mail::Part.new(content_type: 'multipart/alternative',
                                 content_disposition: 'attachment; filename="fwd"')
      forwarded.add_part(Mail::Part.new(content_type: 'text/html', body: '<p>Forwarded</p>'))
      mail.add_part(forwarded)

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    it 'refuses a multipart attachment that has no filename' do
      mail = text_only_mail
      forwarded = Mail::Part.new(content_type: 'multipart/alternative', content_disposition: 'attachment')
      forwarded.add_part(Mail::Part.new(content_type: 'text/html', body: '<p>Forwarded</p>'))
      mail.add_part(forwarded)

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    it 'refuses an attachment that has no filename, and does not send it as a body' do
      mail = text_only_mail
      mail.add_part(Mail::Part.new(content_type: 'text/html', content_disposition: 'attachment',
                                   body: '<p>Notes</p>'))

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    it 'refuses a content header PostHog does not carry, such as Content-Language' do
      mail = shipped_mail
      mail['Content-Language'] = 'de'

      expect(refusal_of(mail)).to eq('unsupported_header')
    end

    it 'refuses a header PostHog does not carry on a body part too' do
      mail = shipped_mail
      mail.html_part['Content-Language'] = 'de'

      expect(refusal_of(mail)).to eq('unsupported_header')
    end

    it 'sends a UTF-8 text attachment, and refuses one in a charset its MIME type would drop' do
      utf8 = shipped_mail
      utf8.attachments['notes.txt'] = 'café'
      latin1 = shipped_mail
      latin1.attachments['latin.txt'] = { mime_type: 'text/plain; charset=ISO-8859-1', content: "caf\xE9".b }

      expect(refusal_of(latin1)).to eq('unsupported_part')
      deliver(utf8)

      expect(sent_files).to eq([{ 'filename' => 'notes.txt', 'content_type' => 'text/plain',
                                  'content' => 'café'.b }])
    end

    it 'refuses a Content-Type parameter PostHog would drop, such as format=flowed' do
      mail = shipped_mail
      mail.text_part.content_type = 'text/plain; charset=UTF-8; format=flowed; delsp=yes'

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    it 'refuses an attachment with a Content-Type parameter PostHog would drop' do
      mail = shipped_mail
      mail.attachments['notes.txt'] = { mime_type: 'text/plain; charset=UTF-8; format=flowed', content: 'Notes' }

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    def related_mail
      mail = Mail.new do
        from 'Shop <shop@example.com>'
        to 'ana@example.com'
        subject 'Your order shipped'
      end
      mail.content_type = 'multipart/related'
      mail.add_part(Mail::Part.new(content_type: 'text/html; charset=UTF-8', body: '<img src="cid:logo">'))
      mail
    end

    it 'refuses an inline resource without a filename instead of sending it as a body' do
      mail = related_mail
      mail.add_part(Mail::Part.new(content_type: 'text/plain; charset=UTF-8', content_disposition: 'inline',
                                   content_id: '<notes>', body: 'Notes'))

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    it 'sends the content ID of a related resource that has no Content-Disposition' do
      mail = related_mail
      mail.add_part(Mail::Part.new(content_type: 'image/png; name=logo.png', content_id: '<logo>',
                                   body: "\x89PNG\r\n\x1A\n".b))

      deliver(mail)

      expect(sent_files).to eq([{ 'filename' => 'logo.png', 'content_type' => 'image/png',
                                  'content' => "\x89PNG\r\n\x1A\n".b, 'content_id' => 'logo' }])
    end

    it 'sends a body part marked inline as a body' do
      mail = shipped_mail
      mail.text_part.content_disposition = 'inline'

      deliver(mail)

      expect(sent_body).to eq(shipped_body)
    end

    # Action Mailer encodes the mail before it delivers it, and encoding gives every inline part a Content-ID.
    it 'sends body parts marked inline as bodies after Action Mailer encodes them' do
      delivery = ShippingMailer.shipped
      delivery.message.text_part.content_disposition = 'inline'
      delivery.message.html_part.content_disposition = 'inline'

      delivery.deliver_now

      expect(sent_body.except('attachments')).to eq(shipped_body.merge('template_key' => 'shipping_mailer-shipped'))
      expect(sent_files.map { |file| file['filename'] }).to eq(['invoice.pdf'])
    end

    it 'refuses text and HTML bodies that are sections of a mixed message, since PostHog sends them as alternatives' do
      mail = Mail.new do
        from 'Shop <shop@example.com>'
        to 'ana@example.com'
        subject 'Your order shipped'
      end
      mail.content_type = 'multipart/mixed'
      mail.add_part(Mail::Part.new(content_type: 'text/plain; charset=UTF-8', body: 'Read the notes below.'))
      mail.add_part(Mail::Part.new(content_type: 'text/html; charset=UTF-8', body: '<p>Notes</p>'))

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    it 'refuses text and HTML sections of a mixed message even when an alternative holds them' do
      mail = Mail.new do
        from 'Shop <shop@example.com>'
        to 'ana@example.com'
        subject 'Your order shipped'
      end
      mail.content_type = 'multipart/alternative'
      sections = Mail::Part.new(content_type: 'multipart/mixed')
      sections.add_part(Mail::Part.new(content_type: 'text/plain; charset=UTF-8', body: 'Read the notes below.'))
      sections.add_part(Mail::Part.new(content_type: 'text/html; charset=UTF-8', body: '<p>Notes</p>'))
      mail.add_part(sections)

      expect(refusal_of(mail)).to eq('unsupported_part')
    end

    it 'names the MIME type of a related image that has no filename' do
      mail = related_mail
      mail.add_part(Mail::Part.new(content_type: 'image/png', content_id: '<logo>', body: "\x89PNG\r\n\x1A\n".b))

      expect { deliver(mail) }.to raise_error(PostHog::Rails::UnsupportedMailError, %r{can't send image/png})
    end

    it 'sends a text alternative to HTML that refers to its own inline image' do
      mail = Mail.new do
        from 'Shop <shop@example.com>'
        to 'ana@example.com'
        subject 'Your order shipped'
      end
      mail.content_type = 'multipart/alternative'
      mail.add_part(Mail::Part.new(content_type: 'text/plain; charset=UTF-8', body: 'On its way.'))
      html = related_mail.parts.first
      related = Mail::Part.new(content_type: 'multipart/related')
      related.add_part(html)
      related.add_part(Mail::Part.new(content_type: 'image/png; name=logo.png', content_id: '<logo>',
                                      body: "\x89PNG\r\n\x1A\n".b))
      mail.add_part(related)

      deliver(mail)

      expect(sent_body.slice('text', 'html')).to eq('text' => 'On its way.', 'html' => '<img src="cid:logo">')
      expect(sent_files.map { |file| file['content_id'] }).to eq(['logo'])
    end

    it 'sends the content ID of an inline attachment as written' do
      mail = shipped_mail
      mail.attachments.inline['logo.png'] = "\x89PNG\r\n\x1A\n".b
      mail.attachments['logo.png'].content_id = '<logo%1@example.com>'

      deliver(mail)

      expect(sent_body['attachments'].first['content_id']).to eq('logo%1@example.com')
    end

    it 'sends normal priority and refuses any other' do
      normal = shipped_mail
      normal['X-Priority'] = '3 (Normal)'
      urgent = shipped_mail
      urgent['Importance'] = 'high'

      expect(refusal_of(urgent)).to eq('unsupported_priority')
      deliver(normal)

      expect(a_request(:post, send_url)).to have_been_made.once
    end

    it 'sends nothing and raises nothing when the mail turns delivery errors off' do
      mail = shipped_mail
      mail.to = ['ana@example.com', 'bo@example.com']
      mail.raise_delivery_errors = false

      log = StringIO.new
      PostHog::Logging.logger = Logger.new(log)

      expect { deliver(mail) }.not_to raise_error
      expect(a_request(:post, send_url)).not_to have_been_made
      expect(log.string).to include('PostHog did not send an email', 'multiple_to')
    end

    it 'refuses a mail PostHog would turn down as invalid, such as one with no subject' do
      no_subject = shipped_mail.tap { |mail| mail.subject = nil }
      spaced_key = shipped_mail.tap { |mail| mail['X-PostHog-Idempotency-Key'] = 'order 1' }

      expect([refusal_of(no_subject), refusal_of(spaced_key)]).to eq(%w[invalid_mail invalid_mail])
    end
  end

  describe 'errors' do
    [
      [400, 'invalid_input', {}, false, nil],
      [401, 'authentication_failed', {}, false, nil],
      [404, 'not_found', {}, false, nil],
      [409, 'idempotency_key_in_flight', {}, true, nil],
      [422, 'recipient_suppressed', {}, false, nil],
      [429, 'quota_limited', {}, false, nil],
      [429, 'throttled', { 'Retry-After' => '5' }, true, 5.0],
      [503, 'delivery_unavailable', {}, true, nil],
      [500, 'server_error', {}, false, nil]
    ].each do |status, code, headers, retryable, retry_after|
      it "raises a #{retryable ? 'retryable' : 'permanent'} DeliveryError for #{status} #{code}" do
        stub_request(:post, send_url).to_return(
          status: status, headers: headers, body: JSON.generate(code: code, detail: 'No.', attr: 'to')
        )

        expect { deliver(shipped_mail) }.to raise_error(PostHog::Rails::DeliveryError) { |error|
          expect([error.status, error.code, error.detail, error.attr]).to eq([status, code, 'No.', 'to'])
          expect([error.retryable?, error.retry_after]).to eq([retryable, retry_after])
          expect(error.cause).to be_a(PostHog::EmailError)
        }
      end
    end

    def invoice_mail
      shipped_mail.tap { |mail| mail.attachments['invoice.pdf'] = "%PDF-1.4\n" }
    end

    it 'raises a permanent DeliveryError when the upload quota is used up' do
      stub_request(:post, %r{/attachments/uploads/\z}).to_return(
        status: 429, body: JSON.generate(code: 'upload_quota_exceeded', detail: 'No.', attr: 'attachments')
      )

      expect { deliver(invoice_mail) }.to raise_error(PostHog::Rails::DeliveryError) { |error|
        expect([error.status, error.code, error.retryable?]).to eq([429, 'upload_quota_exceeded', false])
      }
      expect(a_request(:post, send_url)).not_to have_been_made
    end

    [[500, true], [502, true], [503, true], [504, true], [403, false]].each do |status, retryable|
      it "raises a #{retryable ? 'retryable' : 'permanent'} DeliveryError when file storage answers #{status}" do
        stub_request(:put, %r{\Ahttps://files\.example\.com/}).to_return(status: status, body: '<Error/>')

        expect { deliver(invoice_mail) }.to raise_error(PostHog::Rails::DeliveryError) { |error|
          expect([error.status, error.code, error.retryable?]).to eq([status, 'attachment_upload_failed', retryable])
        }
        expect(a_request(:post, send_url)).not_to have_been_made
      end
    end

    # DeliveryError#retryable? repeats the rule PostHog::Emails retries by. Each failure goes to a client that
    # doesn't retry, to read the error, and to one that retries once, to see whether the SDK sends again.
    it 'calls a failure retryable exactly when the SDK would retry it' do
      once = PostHog.client
      retrying = PostHog::Client.new(api_key: API_KEY, secret_key: 'phs_test', test_mode: true,
                                     email_request_max_retries: 1)
      allow(retrying.emails).to receive(:sleep)
      codes = %w[idempotency_key_in_flight quota_limited upload_quota_exceeded throttled attachment_upload_failed
                 delivery_unavailable server_error invalid_input]
      failures = [400, 401, 403, 404, 409, 422, 429, 500, 502, 503, 504].product(codes).map do |status, code|
        { status: status, body: JSON.generate(code: code, detail: 'No.') }
      end
      accepted = { status: 202, body: JSON.generate(message_id: message_id) }

      (failures + [Errno::ECONNREFUSED]).each do |failure|
        answer = lambda do
          stub = stub_request(:post, send_url)
          failure.is_a?(Hash) ? stub.to_return(failure, accepted) : stub.to_raise(failure).then.to_return(accepted)
        end
        PostHog.client = once
        answer.call
        error = nil
        expect { deliver(shipped_mail) }.to raise_error(PostHog::Rails::DeliveryError) { |raised| error = raised }

        PostHog.client = retrying
        WebMock::RequestRegistry.instance.reset!
        answer.call
        begin
          deliver(shipped_mail)
        rescue PostHog::Rails::DeliveryError
          nil
        end
        attempts = WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(:post, send_url))
        expect(error.retryable?).to eq(attempts == 2), "#{failure.inspect}: sent #{attempts} times"
        WebMock::RequestRegistry.instance.reset!
      end
    ensure
      PostHog.client = once
      retrying&.shutdown
    end

    it 'raises a retryable DeliveryError when PostHog could not be reached' do
      stub_request(:post, send_url).to_raise(Errno::ECONNREFUSED)

      expect { deliver(shipped_mail) }.to raise_error(PostHog::Rails::DeliveryError) { |error|
        expect([error.status, error.code, error.retryable?]).to eq([nil, 'network_error', true])
      }
    end
  end

  describe 'Action Mailer' do
    it 'sends a mailer action with deliver_now, its attachment and the headers Rails adds' do
      ShippingMailer.shipped.deliver_now

      expect(sent_body.except('attachments')).to eq(shipped_body.merge('template_key' => 'shipping_mailer-shipped'))
      expect(sent_files).to eq([{ 'filename' => 'invoice.pdf', 'content_type' => 'application/pdf',
                                  'content' => "%PDF-1.4\n" }])
    end

    it 'sends a deliver_later job with the idempotency key the mail sets' do
      adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.logger = Logger.new(File::NULL)
      ActiveJob::Base.queue_adapter = :inline

      ShippingMailer.shipped('X-PostHog-Idempotency-Key' => 'order-981-shipped').deliver_later

      expect(sent_request.headers['Idempotency-Key']).to eq('order-981-shipped')
    ensure
      ActiveJob::Base.queue_adapter = adapter
    end
  end

  describe 'a Rails app' do
    # Runs each app from a directory of its own, so the files Rails writes when it boots, such as
    # tmp/local_secret.txt, never land in the checkout.
    def run_app(script)
      paths = %w[lib posthog-rails/lib].map { |path| "-I#{File.expand_path("../../../#{path}", __dir__)}" }
      stdout, stderr, status = Dir.mktmpdir do |root|
        Open3.capture3(RbConfig.ruby, *paths, '-e', script, chdir: root)
      end
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      stdout
    end

    it 'sends UserMailer#welcome through delivery_method :posthog with deliver_now' do
      output = run_app(<<~RUBY)
        require 'rails'
        require 'action_mailer/railtie'
        require 'posthog'
        require 'posthog/rails'
        require 'webmock'
        include WebMock::API
        WebMock.enable!

        class App < Rails::Application
          config.eager_load = false
          config.logger = Logger.new(File::NULL)
          config.action_mailer.delivery_method = :posthog
          config.action_mailer.posthog_settings = { default_template_key: 'transactional' }
        end
        App.initialize!

        class UserMailer < ActionMailer::Base
          def welcome
            mail(from: 'shop@example.com', to: 'ana@example.com', subject: 'Welcome') { |f| f.text { render plain: 'Hi' } }
          end
        end

        stub_request(:get, %r{/flags/definitions}).to_return(status: 200, body: '{"flags":[]}')
        stub_request(:post, '#{send_url}').to_return(status: 202, body: '{"message_id":"#{message_id}"}')
        PostHog.init(api_key: 'phc_test', secret_key: 'phs_test', test_mode: true)
        UserMailer.welcome.deliver_now
        WebMock::RequestRegistry.instance.requested_signatures.hash.each_key do |request|
          puts request.body if request.method == :post
        end
      RUBY

      expect(JSON.parse(output)).to include('to' => 'ana@example.com', 'template_key' => 'user_mailer-welcome',
                                            'text' => 'Hi')
    end

    it 'boots without Action Mailer and loads none of the delivery method' do
      output = run_app(<<~RUBY)
        require 'rails'
        require 'posthog'
        require 'posthog/rails'

        class App < Rails::Application
          config.eager_load = false
          config.logger = Logger.new(File::NULL)
        end
        App.initialize!
        p [defined?(ActionMailer), defined?(PostHog::Rails::DeliveryMethod)]
      RUBY

      expect(output.strip).to eq('[nil, nil]')
    end
  end
end
