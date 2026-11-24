# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'date'
require 'securerandom'
require 'time'
require 'uri'
require 'zlib'

require 'posthog/email_attachments'
require 'posthog/email_batch'
require 'posthog/email_error'
require 'posthog/logging'
require 'posthog/utils'

module PostHog
  # Sends transactional email, from an email template made in PostHog or from content your code rendered,
  # and reads the status of each email sent. Reach it through {Client#emails}.
  #
  # A send needs the client's `secret_key`, a project secret API key (`phs_...`) with the
  # `transactional_email:write` scope: the "Send transactional email" preset in your project settings. A key with
  # only `transactional_email:read` can read statuses but not send. Keys made with `hog_flow:write` still work.
  # Sends go to the PostHog app host: a client on PostHog Cloud uses its region's app host, and any other `host`
  # needs `app_host`, because a reverse proxy for ingestion must not receive the secret key.
  #
  # Each send retries network errors, rate limits and an unavailable service, waiting about 1 and then 2 seconds,
  # or the server's `Retry-After` when that is longer. Every attempt sends the same idempotency key, so a retry
  # never sends twice.
  #
  # @example A template made in PostHog
  #   posthog.emails.send(
  #     to: 'user@example.com',
  #     template_id: '0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b',
  #     template_data: { name: 'Ada' },
  #     distinct_id: 'user_123',
  #     idempotency_key: 'welcome:user_123'
  #   )
  #
  # @example Content your code rendered, such as React Email output
  #   posthog.emails.send(
  #     to: 'user@example.com',
  #     template_key: 'password-reset',
  #     subject: 'Reset your password',
  #     html: rendered_html,
  #     distinct_id: 'user_123'
  #   )
  #
  # @example An email scheduled for tomorrow, on PostHog Cloud
  #   result = posthog.emails.send(
  #     to: 'user@example.com',
  #     template_id: '0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b',
  #     scheduled_at: Time.now + 86_400,
  #     idempotency_key: 'trial-ending:user_123'
  #   )
  #   result.status # => "scheduled"
  #   result.scheduled_at # => the time in UTC
  #
  # @example The same template for many recipients, one email each
  #   result = posthog.emails.batch(
  #     template_id: '0190f6d2-7c1e-7b3a-9f5e-1c2d3e4f5a6b',
  #     recipients: [
  #       { to: 'ada@example.com', idempotency_key: 'launch:ada', template_data: { name: 'Ada' } },
  #       { to: 'alan@example.com', idempotency_key: 'launch:alan', template_data: { name: 'Alan' } }
  #     ]
  #   )
  #   result.results.reject { |email| email.status == 'queued' } # => send these again with the same keys
  class Emails
    include PostHog::Logging
    include PostHog::Utils

    # The accepted email. A result means PostHog queued or scheduled the email, not that it was delivered.
    #
    # @!attribute [r] id
    #   @return [String] The accepted email's message ID.
    # @!attribute [r] replayed
    #   @return [Boolean] Whether PostHog had already accepted this idempotency key and returned the first result.
    # @!attribute [r] warnings
    #   @return [Array<Warning>]
    # @!attribute [r] scheduled_at
    #   @return [Time, nil] When a scheduled email goes out, in UTC. +nil+ for an email that goes out now, also when
    #     its +scheduled_at+ had already passed when PostHog accepted it.
    SendResult = Struct.new(:id, :replayed, :warnings, :scheduled_at, keyword_init: true) do
      # @return [String] `scheduled` when the email waits for its {#scheduled_at}, `queued` when it goes out now.
      def status
        scheduled_at.nil? ? 'queued' : 'scheduled'
      end
    end

    # A warning PostHog returned with a queued email.
    Warning = Struct.new(:code, :message, :fix, keyword_init: true)

    # What happened to an email that {Emails#send} queued.
    #
    # @!attribute [r] status
    #   @return [String] `scheduled`, `queued`, `sent`, `failed`, `delivered`, `bounced` or `complained`. A
    #     scheduled email reads `scheduled` until it goes out. Later SDK versions can see values this list does not
    #     have yet.
    # @!attribute [r] reason
    #   @return [String, nil] Why a failed email was not sent, such as `recipient_suppressed`, or the bounce type
    #     of a bounced email: `hard`, `soft` or `unknown`.
    Status = Struct.new(:id, :status, :created_at, :status_at, :reason, keyword_init: true)

    # What happened to one recipient of {Emails#batch}.
    #
    # @!attribute [r] index
    #   @return [Integer] The recipient's position in +recipients+.
    # @!attribute [r] to
    #   @return [String] The recipient's email address.
    # @!attribute [r] idempotency_key
    #   @return [String] The recipient's key, given or made by the client.
    # @!attribute [r] status
    #   @return [String] One of:
    #     - `queued`: PostHog accepted the email. Read it with {Emails#get} to see whether it went out.
    #     - `failed`: PostHog didn't queue the email, and {#error} says why, such as a suppressed address.
    #     - `unconfirmed`: the client can't tell whether PostHog queued the email, such as after a lost answer. It may
    #       still go out. Send it again with the same +idempotency_key+ within 24 hours, so it goes out once.
    #     - `not_attempted`: an earlier request of the batch failed, so the client sent nothing for this recipient.
    # @!attribute [r] message_id
    #   @return [String, nil] The email's message ID, when PostHog named it.
    # @!attribute [r] replayed
    #   @return [Boolean] Whether an earlier send with the same key had already queued the email, so no new email
    #     went out.
    # @!attribute [r] error
    #   @return [EmailError, nil] Why the email is not `queued`. For an `unconfirmed` email, {EmailError#code} is
    #     `delivery_unavailable`, `idempotency_key_in_flight` or `api_error`.
    # @!attribute [r] later_error
    #   @return [EmailError, nil] For an `unconfirmed` email, what a retry in the same call answered about it, which
    #     describes only that retry.
    BatchEmailResult = Struct.new(:index, :to, :idempotency_key, :status, :message_id, :replayed, :error, :later_error,
                                  keyword_init: true)

    # The answer to {Emails#batch}.
    #
    # @!attribute [r] results
    #   @return [Array<BatchEmailResult>] One result per recipient, in the order of +recipients+.
    # @!attribute [r] warnings
    #   @return [Array<Warning>] Warnings PostHog returned about the batch, each once.
    BatchResult = Struct.new(:results, :warnings, keyword_init: true)

    SEND_PATH = '/api/messaging/send/email/'
    UPLOADS_PATH = '/api/messaging/attachments/uploads/'
    STATUS_PATH = '/api/messaging/emails/%<message_id>s/'
    BATCH_PATH = '/api/messaging/send/email_batch/'
    STATUS_BY_KEY_PATH = '/api/messaging/emails/status/'
    # PostHog waits up to 30 seconds for its pipeline before it answers a batch. Connecting and writing keep the
    # client's timeout.
    BATCH_ATTEMPT_TIMEOUT_SECONDS = 45.0
    BATCH_RECIPIENT_FIELDS = %w[to distinct_id idempotency_key template_data].freeze
    US_APP_HOST = 'https://us.posthog.com'
    EU_APP_HOST = 'https://eu.posthog.com'
    SCHEDULING_APP_HOSTS = [US_APP_HOST, EU_APP_HOST].freeze
    CLOUD_APP_HOSTS = {
      'https://us.i.posthog.com' => US_APP_HOST,
      'https://us.posthog.com' => US_APP_HOST,
      'https://app.posthog.com' => US_APP_HOST,
      'https://eu.i.posthog.com' => EU_APP_HOST,
      'https://eu.posthog.com' => EU_APP_HOST
    }.freeze
    MAX_RETRY_DELAY_SECONDS = 30.0
    UUID_PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    IDEMPOTENCY_KEY_PATTERN = /\A[\x21-\x7e]{1,255}\z/
    TEMPLATE_KEY_PATTERN = /\A[a-zA-Z0-9_-]{1,400}\z/
    HEADER_TOKEN_PATTERN = /\A[\x21-\x7e]+\z/
    SCHEDULED_AT_PATTERN = /
      \A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?
      (?:Z|([+-]\d{2}):?(\d{2}))\z
    /x
    SEND_NOW_TOLERANCE_SECONDS = 60
    SCHEDULED_AT_NEEDED = 'scheduled_at must be a Time, or an ISO 8601 time with an offset, such as ' \
                          '2026-12-01T09:00:00Z or 2026-12-01T10:00:00+01:00, so no email was sent.'
    JSON_CONTENT = { 'Content-Type' => 'application/json' }.freeze
    SEND_KEY_NEEDED = 'Sending email needs secret_key, a project secret API key with the ' \
                      'transactional_email:write scope.'
    READ_KEY_NEEDED = 'Reading an email status needs secret_key, a project secret API key with the ' \
                      'transactional_email:read or transactional_email:write scope.'
    TEMPLATE_FORM_WHY = 'A template made in PostHog sets its own sender, subject and content, and follows the ' \
                        "project's engagement setting."
    CODE_FORM_WHY = 'A send with template_key takes its content from your code.'
    TEMPLATE_FIELDS = %i[template_data].freeze
    CODE_FIELDS = %i[subject html text from reply_to cc bcc attachments sensitive tracking capture_engagement].freeze
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, Zlib::Error
    ].freeze
    private_constant :SEND_PATH, :UPLOADS_PATH, :STATUS_PATH, :BATCH_PATH, :STATUS_BY_KEY_PATH,
                     :BATCH_ATTEMPT_TIMEOUT_SECONDS, :BATCH_RECIPIENT_FIELDS, :US_APP_HOST, :EU_APP_HOST,
                     :CLOUD_APP_HOSTS,
                     :SCHEDULING_APP_HOSTS, :MAX_RETRY_DELAY_SECONDS, :UUID_PATTERN, :IDEMPOTENCY_KEY_PATTERN,
                     :TEMPLATE_KEY_PATTERN, :HEADER_TOKEN_PATTERN, :SCHEDULED_AT_PATTERN, :SEND_NOW_TOLERANCE_SECONDS,
                     :SCHEDULED_AT_NEEDED,
                     :JSON_CONTENT, :SEND_KEY_NEEDED, :READ_KEY_NEEDED, :TEMPLATE_FORM_WHY, :CODE_FORM_WHY,
                     :TEMPLATE_FIELDS, :CODE_FIELDS, :NETWORK_ERRORS

    # @api private
    def initialize(secret_key:, host:, app_host:, timeout:, max_retries:, migrated_from:, user_agent:, disabled:,
                   skip_ssl_verification: false)
      check_options(timeout, max_retries, migrated_from)
      @secret_key = secret_key.is_a?(String) ? secret_key.strip : nil
      @app_host = resolve_app_host(host, app_host)
      @timeout = timeout
      @max_retries = max_retries
      @migrated_from = migrated_from
      @user_agent = user_agent
      @disabled = disabled
      @skip_ssl_verification = skip_ssl_verification
      @closed = false
      @in_flight = 0
      @pid = Process.pid
      @mutex = Mutex.new
      @idle = ConditionVariable.new
    end

    # Queues one email, from a template made in PostHog or from content your code rendered.
    #
    # Pass exactly one form. The template form names a template made in PostHog with `template_id`. The code form
    # names the email with `template_key` and passes `subject` and `html`, `text` or both. To send a React email,
    # render it to HTML in your app first.
    #
    # @param to [String] One recipient email address.
    # @param template_id [String] Template form: the UUID of a template made transactional in PostHog.
    # @param template_data [Hash] Template form: values for the template's `{{ variables.* }}` placeholders.
    # @param template_key [String] Code form: names the email, such as `password-reset`, so its metrics, logs and
    #   status group under it in PostHog. Letters, digits, hyphens and underscores, at most 400.
    # @param subject [String] Code form: the subject line.
    # @param html [String] Code form: the HTML body.
    # @param text [String] Code form: the plain-text body. Without it, PostHog derives it from `html`.
    # @param from [String] Code form: a verified sender, such as `Acme <hello@example.com>`. Without it, the
    #   project's default sender.
    # @param reply_to [String, Array<String>] Code form: one address or a list of addresses.
    # @param cc [String, Array<String>] Code form: one address or a list of addresses that get a visible copy, at
    #   most 10. An empty list sends no copy.
    # @param bcc [String, Array<String>] Code form: one address or a list of addresses that get a hidden copy, at
    #   most 10. An empty list sends no copy.
    # @param attachments [Array<Hash>] Code form: files sent with the email, at most 10 files and 40 MB per email
    #   after Base64 encoding, about 29 MB of files. The client hashes each file, uploads the files PostHog doesn't
    #   have yet straight to PostHog's file storage, then sends the email naming the files by their SHA-256. A file
    #   sent before by the same project uploads nothing again. Each file is a Hash with:
    #   - +filename+ [String] the name the recipient sees, such as `invoice.pdf`;
    #   - +content+ [String, Array<Integer>] the file's bytes, as a binary String such as `File.binread(path)`
    #     returns or as a list of byte values. Any other String is taken as the file encoded as Base64, on one
    #     line or wrapped at 60, 64 or 76 characters. PostHog can't fetch a file from a path or URL;
    #   - +content_type+ [String] the MIME type, optional. Without it, the type follows the file name;
    #   - +content_id+ [String] optional: shows the file inline where `html` has `<img src="cid:...">` with this ID.
    # @param sensitive [Boolean] Code form: +true+ when the email carries login links, reset tokens or codes. A
    #   sensitive email keeps its links unchanged unless +tracking+ turns clicks on, leaves its subject off engagement
    #   events, and keeps its content out of logs. Left out, the email takes the setting of the template made in
    #   PostHog whose key matches +template_key+, and is sensitive when no template matches. Sent only when you set
    #   it, and needs a PostHog version that takes it.
    # @param tracking [Boolean, Hash] Code form: what PostHog tracks for the email. Left out, PostHog counts opens and
    #   captures engagement events, and tracks clicks only when the email isn't sensitive. +true+ turns on opens,
    #   clicks and engagement events, even for a sensitive email. +false+ turns them all off: the email has no open
    #   pixel and no rewritten links, and PostHog captures no engagement events for it. A Hash such as
    #   +{ clicks: true }+ sets +:opens+ (default +true+), +:clicks+ (default: on unless the email is sensitive) and
    #   +:engagement+ (default +true+) one by one. Turn clicks on for a sensitive email only when its links are safe to
    #   rewrite. Click tracking needs open tracking. A project whose admin turned engagement capture off captures
    #   nothing, whatever the send says. Sent only when you set it, and needs a PostHog version that takes it.
    # @param capture_engagement [Boolean] Deprecated: use +tracking: { engagement: false }+ instead. Code form:
    #   whether PostHog captures the email's engagement events. It still works, but a send can't set both. Sent
    #   only when you set it.
    # @param distinct_id [String] The recipient's distinct ID in your product. The email's events go to this
    #   person. Without it, they go to a person whose distinct ID is the email address.
    # @param idempotency_key [String] 1 to 255 visible ASCII characters. A send with a key PostHog has already
    #   accepted queues nothing and returns the first send's result. Without it, the client makes a UUID that covers
    #   its own retries. Pass a key derived from what the email is for, such as `welcome:user_123`, when a job runner
    #   retries the send.
    # @param max_retries [Integer] Overrides the client's `email_request_max_retries` for this send. +0+ turns
    #   retries off.
    # @param scheduled_at [Time, DateTime, String] When to send the email, at most 7 days ahead: a +Time+, such as
    #   +Time.now + 3600+ or a Rails time with zone, a +DateTime+, or an ISO 8601 time with an offset, such as
    #   `2026-12-01T10:00:00+01:00`. A time that has passed sends the email now. PostHog keeps the time to the
    #   millisecond, and the client rounds a finer time up to the next millisecond, so the email never goes out early,
    #   and sends that time on every retry. Work out a relative time once and pass the same time when you send again
    #   with the same +idempotency_key+: another time with that key raises `idempotency_key_reused`. Only PostHog Cloud
    #   schedules emails. To stop scheduled emails, disable the email's workflow in PostHog until they have reached a
    #   final status, which refuses every new send of it meanwhile.
    # @return [SendResult] The accepted email.
    # @raise [EmailError] PostHog did not queue the email, or the client could not tell whether it did.
    #   With +scheduled_at+, {EmailError#code} is `scheduling_requires_cloud` before any request when the client's
    #   app host isn't PostHog Cloud US or EU, such as a self-hosted PostHog, a reverse proxy or a custom domain, which
    #   could send the email at once. It is `schedule_not_confirmed` when PostHog accepted the email without confirming
    #   its time, also when PostHog sends now an email due more than a minute ahead by this machine's clock: the email
    #   exists and may go out at another time, and {EmailError#message_id} names it. Read it with {#get} before you
    #   send again. When the logger raises while it logs the reply's warnings, its error propagates with this one as
    #   its +cause+.
    #   Before any request, {EmailError#code} is `invalid_attachment` for a file the client can't send,
    #   `too_many_attachments` for more than 10 files, and `message_too_large` for files too large for one email.
    #   It is `attachment_upload_failed` when file storage refused an upload, and `not_found` with
    #   {EmailError#field} `attachments` when PostHog has no upload route for this project. Unless `app_host` is
    #   an http URL, an upload URL without https raises `api_error` on the file's field, such as
    #   `attachments__0`, before any file goes out. No email was sent.
    # @raise [ArgumentError] An argument has the wrong type or format, such as a +scheduled_at+ without an offset, or
    #   the call mixes the two forms.
    def send(
      to:, template_id: nil, template_data: nil, template_key: nil, subject: nil, html: nil, text: nil, from: nil,
      reply_to: nil, cc: nil, bcc: nil, attachments: nil, sensitive: nil, tracking: nil, capture_engagement: nil,
      distinct_id: nil, idempotency_key: nil, max_retries: nil, scheduled_at: nil
    )
      fields = {
        template_data: template_data, subject: subject, html: html, text: text, from: from, reply_to: reply_to,
        cc: cc, bcc: bcc, attachments: attachments, sensitive: sensitive, tracking: tracking,
        capture_engagement: capture_engagement
      }.compact
      check_recipient(to, distinct_id, idempotency_key, max_retries)
      payload = content(template_id, template_key, fields).merge(to: to)
      due = scheduled_time(scheduled_at)
      files = EmailAttachments.from(fields.fetch(:attachments, []), bodies_with_derived_text(fields), fields[:subject])
      payload[:attachments] = files.references unless files.empty?
      payload[:distinct_id] = distinct_id unless distinct_id.nil?
      payload[:scheduled_at] = time_in_iso8601(due) if due
      body = JSON.generate(payload)
      headers = { 'Content-Type' => 'application/json', 'Idempotency-Key' => idempotency_key || SecureRandom.uuid }

      result, unconfirmed = call('no email was sent', SEND_KEY_NEEDED) do |secret_key|
        check_schedulable if due
        upload(files, secret_key, max_retries || @max_retries) unless files.empty?
        uri = URI(@app_host + SEND_PATH)
        # A slow reply must not move a time that was more than a minute ahead into the send-now window.
        sent_at = Time.now
        with_retries(max_retries || @max_retries) do
          parse_send_reply(request(Net::HTTP::Post.new(uri), uri, secret_key, headers, body), due, sent_at)
        end
      end
      begin
        raise unconfirmed if unconfirmed
      ensure
        # The client can't tell a failing logger from a caller's deadline, so either propagates. A logger's own error
        # keeps schedule_not_confirmed as its cause.
        result.warnings.each { |warning| logger.warn("PostHog email warning #{warning.code}: #{warning.message}") }
      end

      result
    end

    # Queues the same email for many recipients, one email each, from a template made in PostHog or from content
    # your code rendered.
    #
    # Pass the template form, with +template_id+, or the code form, with +template_key+, as {#send} takes them. The
    # client sends the recipients in requests of at most 100 recipients and 4 MiB of JSON, one after another, and
    # waits at least 45 seconds for each answer. A batch takes no +cc+, +bcc+, +attachments+ or +scheduled_at+.
    #
    # Each recipient has an +idempotency_key+, given or made by the client, that every retry reuses, so a retry never
    # queues an email twice. Retries follow {#send}'s. When a request of the batch fails as a whole, the client reads
    # by its key each email of the batch whose answer was lost.
    #
    # @param recipients [Array<Hash>] 1 or more recipients, each a Hash with:
    #   - +to+ [String] the recipient's email address;
    #   - +distinct_id+ [String] optional: the recipient's distinct ID in your product;
    #   - +idempotency_key+ [String] optional: 1 to 255 visible ASCII characters, a different one for each recipient.
    #     Without it, the client makes one that covers its own retries but not a second call, so pass keys you store
    #     when a batch may be cut off and run again: a rerun within 24 hours replays the emails that went out instead
    #     of sending them twice. A send and a batch recipient with the same key and the same email replay each other.
    #     Never reuse a key for another email: after a lost answer, the client reads the email by its key, and an
    #     earlier email with that key reads as this one, `queued`;
    #   - +template_data+ [Hash] optional, only with +template_id+: values for this recipient, merged over the
    #     batch's +template_data+. A top-level key set here replaces the same key there.
    # @param template_id [String] Template form: the UUID of a template made transactional in PostHog.
    # @param template_data [Hash] Template form: values for the template, shared by every recipient.
    # @param template_key [String] Code form: names the email, as {#send} takes it. Pass +subject+ and +html+, +text+
    #   or both, and optionally +from+, +reply_to+, +sensitive+, +tracking+ and +capture_engagement+, the same for
    #   every recipient. A recipient can't carry +template_data+: send personalized content with a +template_id+
    #   batch, or with {#send}.
    # @param max_retries [Integer] Overrides the client's `email_request_max_retries` for each request of the batch.
    #   +0+ turns retries off.
    # @return [BatchResult] A result per recipient, in the order of +recipients+. Check each
    #   {BatchEmailResult#status}, and send an `unconfirmed` email again with the same key so it goes out once.
    # @raise [EmailBatchError] A request failed as a whole, such as a rate limit past its retries, so the batch
    #   stopped. {EmailBatchError#results} holds every recipient, those not sent as `not_attempted`.
    #   {EmailError#code} is `batch_unavailable` when the project can't send batches yet, and `not_found` when the
    #   template doesn't exist or batch sends are off: send each email the batch didn't queue with {#send} and its
    #   recipient's +idempotency_key+. It is `client_closed` when the client shut down during the batch. When the
    #   logger raises while it logs the warnings, its error propagates with this one as its +cause+.
    # @raise [EmailError] The client sent nothing, such as when it is disabled or has no +secret_key+.
    # @raise [ArgumentError] An argument has the wrong type or format, such as two recipients with the same
    #   +idempotency_key+.
    def batch(
      recipients:, template_id: nil, template_data: nil, template_key: nil, subject: nil, html: nil, text: nil,
      from: nil, reply_to: nil, sensitive: nil, tracking: nil, capture_engagement: nil, max_retries: nil
    )
      unless max_retries.nil? || retry_count?(max_retries)
        raise ArgumentError,
              'max_retries must be a nonnegative integer.'
      end

      fields = {
        template_data: template_data, subject: subject, html: html, text: text, from: from, reply_to: reply_to,
        sensitive: sensitive, tracking: tracking, capture_engagement: capture_engagement
      }.compact
      shared = content(template_id, template_key, fields)
      members = batch_members(recipients, template_key.nil?)
      run = EmailBatch.new(shared, members, parse_warnings: method(:warnings), reply_error: method(:reply_error))

      failure = call('no email was sent', SEND_KEY_NEEDED) do |secret_key|
        send_chunks(run, secret_key, max_retries || @max_retries)
      end
      result = failure || run.result
      begin
        raise failure if failure
      ensure
        # A logger's own error keeps the batch's error as its cause.
        result.warnings.each { |warning| logger.warn("PostHog email warning #{warning.code}: #{warning.message}") }
      end

      result
    end

    # Reads what happened to an email that {#send} queued, for 30 days after the send.
    #
    # @param message_id [String] The {SendResult#id} that {#send} returned.
    # @return [Status] The email's latest status.
    # @raise [EmailError] PostHog did not answer with a status. {EmailError#code} is `not_found` for an unknown ID,
    #   an email older than 30 days, or for a few seconds after the send.
    # @raise [ArgumentError] +message_id+ is not a message ID.
    def get(message_id)
      raise ArgumentError, 'message_id must be the message ID that send returned.' unless uuid?(message_id)

      call('no email status was read', READ_KEY_NEEDED) do |secret_key|
        uri = URI(@app_host + format(STATUS_PATH, message_id: message_id.downcase))
        with_retries(@max_retries) { parse_status_reply(request(Net::HTTP::Get.new(uri), uri, secret_key, {})) }
      end
    end

    # Refuses new sends and waits for the sends and status reads in flight, retries included, to settle.
    #
    # @api private
    # @param timeout [Numeric, nil] Maximum seconds to wait, or +nil+ to wait until they settle.
    # @return [Boolean] +true+ if nothing is in flight any more.
    def close(timeout: nil)
      deadline = timeout && (monotonic_time + timeout)
      @mutex.synchronize do
        forget_parent_requests
        @closed = true
        until @in_flight.zero?
          remaining = deadline && (deadline - monotonic_time)
          break if remaining && remaining <= 0

          @idle.wait(@mutex, remaining)
        end
        @in_flight.zero?
      end
    end

    private

    def batch_members(recipients, template_form)
      unless recipients.is_a?(Array)
        raise ArgumentError,
              "recipients must be an Array of recipients, each a Hash with to, such as [{ to: 'user@example.com' }]."
      end
      raise ArgumentError, 'recipients must hold at least one recipient.' if recipients.empty?

      first_with_key = {}
      recipients.each_with_index.map do |recipient, index|
        fields = batch_recipient_fields(recipient, index)
        member = batch_member(fields, index, template_form)
        first = first_with_key[member.idempotency_key] ||= index
        unless first == index
          raise ArgumentError, "recipients[#{index}] has the same idempotency_key as recipients[#{first}]. Give each " \
                               'recipient its own key.'
        end

        member
      end
    end

    def batch_recipient_fields(recipient, index)
      fields = recipient.is_a?(Hash) ? Utils.stringify_keys(recipient) : {}
      unless fields.key?('to')
        raise ArgumentError, "recipients[#{index}] must be a Hash with to, such as { to: 'user@example.com' }."
      end

      unknown = fields.keys - BATCH_RECIPIENT_FIELDS
      return fields if unknown.empty?

      raise ArgumentError, "recipients[#{index}] takes only to, distinct_id, idempotency_key and template_data, not " \
                           "#{unknown.join(', ')}."
    end

    def batch_member(fields, index, template_form)
      to, distinct_id, key, data = fields.values_at('to', 'distinct_id', 'idempotency_key', 'template_data')
      begin
        check_recipient(to, distinct_id, key, nil)
      rescue ArgumentError => e
        raise ArgumentError, "recipients[#{index}]: #{e.message}"
      end
      key ||= SecureRandom.uuid
      wire = { to: to, idempotency_key: key }
      wire[:distinct_id] = distinct_id unless distinct_id.nil?
      unless data.nil?
        unless template_form
          raise ArgumentError, "recipients[#{index}] has template_data, but a batch with template_key sends the same " \
                               'content to every recipient. Send personalized content with a template_id batch or ' \
                               'with emails.send.'
        end
        raise ArgumentError, "recipients[#{index}]: template_data must be a Hash." unless data.is_a?(Hash)

        wire[:message_data] = isoify_dates(data)
      end
      EmailBatch::Member.new(index: index, to: to, idempotency_key: key, wire: JSON.generate(wire))
    end

    def send_chunks(run, secret_key, max_retries)
      run.chunks.each_with_index do |chunk, position|
        return run.failure(run.closed_at(position)) if position.positive? && !still_admitted?

        begin
          send_chunk(run, chunk, secret_key, max_retries)
        rescue EmailError => e
          run.stop(position, e)
          read_lost(run, secret_key)
          return run.failure(e)
        end
      end
      nil
    end

    def send_chunk(run, chunk, secret_key, max_retries)
      uri = URI(@app_host + BATCH_PATH)
      read_timeout = [@timeout.to_f, BATCH_ATTEMPT_TIMEOUT_SECONDS].max
      body = chunk.body
      with_retries(max_retries) do |attempt|
        if attempt.positive? && !still_admitted?
          raise EmailError.new(
            code: 'client_closed',
            message: "The PostHog client is shut down, so it didn't retry this request of the batch."
          )
        end

        begin
          reply = request(Net::HTTP::Post.new(uri), uri, secret_key, JSON_CONTENT, body, read_timeout: read_timeout)
        rescue EmailError
          run.lost(chunk)
          raise
        end
        run.answer(chunk, reply)
      end
    end

    # After a lost answer, a status read by key tells whether PostHog accepted the email. It reads each key once and
    # stops at the first error but a 404, so a failing PostHog doesn't hold the caller up.
    def read_lost(run, secret_key)
      run.lost_keys.each do |index, key|
        break unless still_admitted?

        status = status_by_key(key, secret_key)
        break if status == :stop

        run.found(index, status) if status
      end
    end

    def status_by_key(key, secret_key)
      uri = URI("#{@app_host}#{STATUS_BY_KEY_PATH}?#{URI.encode_www_form(idempotency_key: key)}")
      parse_status_reply(request(Net::HTTP::Get.new(uri), uri, secret_key, {}))
    rescue EmailError => e
      e.status_code == 404 ? nil : :stop
    end

    def still_admitted?
      @mutex.synchronize do
        forget_parent_requests
        !@closed
      end
    end

    def check_options(timeout, max_retries, migrated_from)
      raise ArgumentError, 'email_request_timeout_seconds must be a positive number.' unless positive?(timeout)
      raise ArgumentError, 'email_request_max_retries must be a nonnegative integer.' unless retry_count?(max_retries)
      return if migrated_from.nil? || (migrated_from.is_a?(String) && HEADER_TOKEN_PATTERN.match?(migrated_from))

      raise ArgumentError, "migrated_from must be visible ASCII characters, such as 'resend'."
    end

    def positive?(value)
      value.is_a?(Numeric) && value.real? && value.positive? && value.finite?
    end

    def retry_count?(value)
      value.is_a?(Integer) && value >= 0
    end

    def uuid?(value)
      value.is_a?(String) && UUID_PATTERN.match?(value)
    end

    def bodies_with_derived_text(fields)
      html, text = fields.values_at(:html, :text)
      [html, text.to_s.empty? ? html : text].compact
    end

    def resolve_app_host(host, app_host)
      explicit = app_host.is_a?(String) ? app_host.strip.chomp('/') : ''
      return CLOUD_APP_HOSTS[host.to_s.strip.chomp('/')] if explicit.empty?
      # A host without a scheme would send the secret key to the wrong place, such as localhost.
      unless web_url?(explicit)
        raise ArgumentError, 'app_host must be an http or https URL, such as https://us.posthog.com.'
      end

      CLOUD_APP_HOSTS.fetch(explicit, explicit)
    end

    def web_url?(value)
      uri = URI(value)
      %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end

    def check_recipient(to, distinct_id, idempotency_key, max_retries)
      raise ArgumentError, 'to must be one email address as a nonempty string.' unless nonempty_string?(to)
      unless distinct_id.nil? || nonempty_string?(distinct_id)
        raise ArgumentError, 'distinct_id must be a nonempty string.'
      end
      unless idempotency_key.nil? || (idempotency_key.is_a?(String) && IDEMPOTENCY_KEY_PATTERN.match?(idempotency_key))
        raise ArgumentError, 'idempotency_key must be 1 to 255 visible ASCII characters without spaces.'
      end
      return if max_retries.nil? || retry_count?(max_retries)

      raise ArgumentError, 'max_retries must be a nonnegative integer.'
    end

    def nonempty_string?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def scheduled_time(value)
      return nil if value.nil?

      instant = case value
                when DateTime then Time.at((value - DateTime.new(1970, 1, 1)) * 86_400)
                when Time then Time.at(value.to_r)
                when String then offset_time(value)
                end
      raise ArgumentError, SCHEDULED_AT_NEEDED if instant.nil?

      instant.utc.ceil(3)
    end

    def offset_time(value)
      return nil unless value.valid_encoding?

      parts = SCHEDULED_AT_PATTERN.match(value)
      return nil if parts.nil?

      year, month, day, hour, minute, second, fraction, offset_hours, offset_minutes = parts.captures
      return nil unless Date.valid_date?(year.to_i, month.to_i, day.to_i, Date::GREGORIAN)
      return nil unless hour.to_i <= 23 && minute.to_i <= 59 && second.to_i <= 59
      return nil unless offset_hours.to_s[1, 2].to_i <= 23 && offset_minutes.to_i <= 59

      seconds = second.to_i + (fraction ? Rational(fraction.to_i, 10**fraction.size) : 0)
      offset = offset_hours ? "#{offset_hours}:#{offset_minutes}" : '+00:00'
      Time.new(year.to_i, month.to_i, day.to_i, hour.to_i, minute.to_i, seconds, offset)
    end

    def check_schedulable
      return if SCHEDULING_APP_HOSTS.include?(@app_host)

      uri = URI(@app_host)
      host = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
      raise EmailError.new(
        code: 'scheduling_requires_cloud', field: 'scheduled_at',
        message: 'Only PostHog Cloud (us.posthog.com or eu.posthog.com) schedules emails, and this client sends ' \
                 "email to #{host}, so no email was sent.",
        why: "A PostHog that doesn't schedule emails would send this one at once.",
        fix: "Send without scheduled_at, or set app_host to PostHog Cloud's app host. A reverse proxy or custom " \
             "domain can't schedule emails yet."
      )
    end

    def content(template_id, template_key, fields)
      if template_id.nil? == template_key.nil?
        raise ArgumentError, 'Send either template_id, or template_key with subject and html or text.'
      end

      template_key.nil? ? template_content(template_id, fields) : code_content(template_key, fields)
    end

    def template_content(template_id, fields)
      refuse_fields(fields, allowed: TEMPLATE_FIELDS, form: :template_id, other_form: :template_key,
                            why: TEMPLATE_FORM_WHY)
      raise ArgumentError, "template_id must be the template's UUID." unless uuid?(template_id)

      template_data = fields.fetch(:template_data, {})
      raise ArgumentError, 'template_data must be a Hash.' unless template_data.is_a?(Hash)

      { template_id: template_id.downcase, message_data: isoify_dates(template_data) }
    end

    def code_content(template_key, fields)
      refuse_fields(fields, allowed: CODE_FIELDS, form: :template_key, other_form: :template_id,
                            why: CODE_FORM_WHY)
      unless template_key.is_a?(String) && TEMPLATE_KEY_PATTERN.match?(template_key)
        raise ArgumentError,
              'template_key can only have letters, digits, hyphens (-) and underscores (_), at most 400.'
      end
      raise ArgumentError, 'A send with template_key needs a subject.' unless fields[:subject].is_a?(String)
      unless fields.key?(:html) || fields.key?(:text)
        raise ArgumentError,
              'A send with template_key needs html, text or both.'
      end

      %i[html text from].each do |name|
        raise ArgumentError, "#{name} must be a string." if fields.key?(name) && !fields[name].is_a?(String)
      end
      %i[capture_engagement sensitive].each do |name|
        raise ArgumentError, "#{name} must be true or false." unless [nil, true, false].include?(fields[name])
      end

      code = fields.slice(:subject, :html, :text, :from).merge(template_key: template_key)
      code[:reply_to] = addresses(:reply_to, fields[:reply_to]) if fields.key?(:reply_to)
      %i[cc bcc].each do |name|
        list = fields.key?(name) ? addresses(name, fields[name]) : []
        code[name] = list unless list.empty?
      end
      code[:capture_engagement] = fields[:capture_engagement] if fields.key?(:capture_engagement)
      code[:sensitive] = fields[:sensitive] if fields.key?(:sensitive)
      code[:tracking] = tracking(fields[:tracking]) if fields.key?(:tracking)
      code
    end

    def tracking(value)
      return value if [true, false].include?(value)
      raise ArgumentError, 'tracking must be true, false or a Hash such as { clicks: true }.' unless value.is_a?(Hash)

      kinds = value.compact
      kinds.each do |kind, on|
        raise ArgumentError, "tracking[#{kind.inspect}] must be true or false." unless [true, false].include?(on)
      end
      kinds
    end

    def refuse_fields(fields, allowed:, form:, other_form:, why:)
      field = fields.keys.find { |name| !allowed.include?(name) }
      return if field.nil?

      message = "A send with #{form} doesn't take #{field}, so no email was sent."
      raise ArgumentError, "#{message} #{why} Remove #{field}, or send with #{other_form}."
    end

    def addresses(name, value)
      list = value.is_a?(String) ? [value] : value
      return list if list.is_a?(Array) && list.all? { |address| nonempty_string?(address) }

      raise ArgumentError, "#{name} must be one address or a list of addresses."
    end

    def call(nothing_done, key_needed)
      admit(nothing_done)
      begin
        unless @app_host
          # A custom host is often an ingestion proxy, which must not receive the secret key.
          raise EmailError.new(
            code: 'missing_app_host',
            message: "The client's host is not PostHog Cloud, so the client can't tell where to send email. " \
                     'Set app_host to your PostHog app host on the client.'
          )
        end
        raise EmailError.new(code: 'missing_secret_key', message: key_needed) if @secret_key.nil? || @secret_key.empty?

        yield @secret_key
      ensure
        finish
      end
    end

    def admit(nothing_done)
      if @disabled
        raise EmailError.new(code: 'client_disabled',
                             message: "The PostHog client is disabled, so #{nothing_done}.")
      end

      @mutex.synchronize do
        forget_parent_requests
        if @closed
          raise EmailError.new(code: 'client_closed',
                               message: "The PostHog client is shut down, so #{nothing_done}.")
        end

        @in_flight += 1
      end
    end

    # A forked child inherits the parent's count, but not the threads that would settle those requests.
    def forget_parent_requests
      return if @pid == Process.pid

      @pid = Process.pid
      @in_flight = 0
    end

    def finish
      @mutex.synchronize do
        @in_flight -= 1
        @idle.broadcast if @in_flight.zero?
      end
    end

    def with_retries(max_retries)
      attempt = 0
      begin
        yield attempt
      rescue EmailError => e
        delay = retry_delay(e, attempt, max_retries)
        raise if delay.nil?

        sleep(delay)
        attempt += 1
        retry
      end
    end

    def retry_delay(error, attempt, max_retries)
      return nil if attempt >= max_retries || !retryable?(error)
      # Retrying before a longer Retry-After would break the server's rate limit.
      return nil if error.retry_after && error.retry_after > MAX_RETRY_DELAY_SECONDS

      backoff = [MAX_RETRY_DELAY_SECONDS, (2**attempt) * rand(0.8..1.2)].min
      [backoff, error.retry_after || 0].max
    end

    def retryable?(error)
      # A send carries an idempotency key, so a retry can't queue a second email. A status read changes nothing.
      case error.status_code
      when nil then error.code == 'network_error'
      when 409 then error.code == 'idempotency_key_in_flight'
      when 429 then !%w[quota_limited upload_quota_exceeded].include?(error.code)
      when 500, 502, 504 then error.code == 'attachment_upload_failed'
      else error.status_code == 503
      end
    end

    def upload(files, secret_key, max_retries)
      distinct = files.distinct
      uri = URI(@app_host + UPLOADS_PATH)
      body = JSON.generate(files: distinct.map { |file| { sha256: file.sha256, size: file.bytes.bytesize } })
      slots = with_retries(max_retries) do
        parse_uploads_reply(request(Net::HTTP::Post.new(uri), uri, secret_key, JSON_CONTENT, body), distinct)
      end
      distinct.zip(slots).each { |file, slot| put_file(file, slot, max_retries) if slot['status'] == 'upload' }
    end

    def parse_uploads_reply((status, payload, retry_after), files)
      fields = payload.is_a?(Hash) ? payload : {}
      fields = { 'code' => 'not_found', 'attr' => 'attachments' }.merge(fields.compact) if status == 404
      raise reply_error(fields, status, retry_after) unless status.between?(200, 299)

      slots = fields['files']
      unless slots.is_a?(Array) && slots.size == files.size && files.zip(slots).all? { |pair| slot?(*pair) }
        raise EmailError.new(code: 'api_error', message: "PostHog answered without the files' uploads.",
                             status_code: status)
      end
      file_without_tls, = files.zip(slots).find { |_, slot| without_tls?(slot) }
      raise upload_without_tls(file_without_tls, status) if file_without_tls

      slots
    end

    def without_tls?(slot)
      slot['status'] == 'upload' && URI(@app_host).scheme == 'https' && URI(slot['url']).scheme != 'https'
    end

    def upload_without_tls(file, status)
      filename = file.reference['filename']
      EmailError.new(code: 'api_error', field: file.field, status_code: status,
                     message: "PostHog gave an upload URL for #{filename} that isn't https, so no file was uploaded " \
                              'and no email was sent.',
                     why: "Your app_host uses https, and #{filename} would have gone to file storage unencrypted.",
                     fix: "Fix the file storage's URL so it uses https. For local development over http, set " \
                          'app_host to an http URL.')
    end

    def slot?(file, slot)
      return false unless slot.is_a?(Hash) && slot['sha256'] == file.sha256
      return slot['status'] == 'present' unless slot['status'] == 'upload'

      slot['method'] == 'PUT' && web_url?(slot['url'].to_s) && slot['headers'].is_a?(Hash) &&
        slot['headers'].all? { |name, value| name.is_a?(String) && value.is_a?(String) }
    end

    def put_file(file, slot, max_retries)
      uri = URI(slot['url'])
      with_retries(max_retries) do
        request = Net::HTTP::Put.new(uri)
        request['Content-Type'] = 'application/octet-stream'
        status, answer, retry_after = exchange(request, uri, slot['headers'], file.bytes)
        raise upload_failed(file, status, answer, retry_after) unless status.between?(200, 299)
      end
    rescue EmailError => e
      raise unless e.code == 'network_error'

      raise EmailError.new(code: 'network_error', field: file.field, retry_after: e.retry_after,
                           message: "The upload of #{file.reference['filename']} to file storage failed, so no " \
                                    'email was sent.')
    end

    def upload_failed(file, status, answer, retry_after)
      answer = answer.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      storage_said = [answer[%r{<Code>([^<]*)</Code>}, 1], answer[%r{<Message>([^<]*)</Message>}, 1]].compact
      EmailError.new(
        code: 'attachment_upload_failed', status_code: status, field: file.field, retry_after: retry_after,
        message: "File storage refused the upload of #{file.reference['filename']} with HTTP #{status}" \
                 "#{" (#{storage_said.join(': ')})" unless storage_said.empty?}, so no email was sent."
      )
    end

    def request(request, uri, secret_key, headers, body = nil, read_timeout: @timeout)
      request['Authorization'] = "Bearer #{secret_key}"
      request['Accept'] = 'application/json'
      request['User-Agent'] = @user_agent if @user_agent
      request['X-PostHog-Migrated-From'] = @migrated_from if @migrated_from
      status, answer, retry_after = exchange(request, uri, headers, body, read_timeout: read_timeout)
      [status, parse_json(answer), retry_after]
    end

    def exchange(request, uri, headers, body, read_timeout: @timeout)
      headers.each { |name, value| request[name] = value }
      request.body = body if body

      head = nil
      response = Net::HTTP.start(uri.hostname, uri.port, connection_options(uri, read_timeout)) do |http|
        http.request(request) { |started| head = started }
      end
      [response.code.to_i, response.body, parse_retry_after(response['Retry-After'])]
    rescue *NETWORK_ERRORS
      # A reply whose body broke off retries with the same idempotency key, after its Retry-After when it sent one.
      raise EmailError.new(code: 'network_error', message: 'The request to PostHog failed.',
                           retry_after: head && parse_retry_after(head['Retry-After']))
    end

    def connection_options(uri, read_timeout)
      options = {
        use_ssl: uri.scheme == 'https', open_timeout: @timeout, read_timeout: read_timeout, write_timeout: @timeout,
        # Net::HTTP returns a body cut off by a closed connection as if it were whole. Raise instead.
        max_retries: 0, ignore_eof: false
      }
      options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE if @skip_ssl_verification
      options
    end

    def parse_json(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      nil
    end

    def parse_send_reply((status, payload, retry_after), due, sent_at)
      fields = payload.is_a?(Hash) ? payload : {}
      raise reply_error(fields, status, retry_after) unless status.between?(200, 299)

      id = text(fields['message_id'])
      unless id
        raise EmailError.new(code: 'api_error', message: 'PostHog answered without a message ID.',
                             status_code: status)
      end

      result = SendResult.new(id: id, replayed: fields['replayed'] == true, warnings: warnings(fields['warnings']),
                              scheduled_at: nil)
      return [result, nil] if due.nil? || time_had_passed?(fields, due, sent_at)
      return [result, schedule_not_confirmed(id, status)] unless confirms?(fields, due)

      result.scheduled_at = due
      [result, nil]
    end

    def time_had_passed?(fields, due, sent_at)
      fields['status'] == 'queued' && fields.key?('scheduled_at') && fields['scheduled_at'].nil? &&
        due <= sent_at + SEND_NOW_TOLERANCE_SECONDS
    end

    def confirms?(fields, due)
      answered = fields['scheduled_at']
      fields['status'] == 'scheduled' && answered.is_a?(String) && offset_time(answered) == due
    end

    def schedule_not_confirmed(message_id, status)
      EmailError.new(
        code: 'schedule_not_confirmed', status_code: status, field: 'scheduled_at', message_id: message_id,
        message: "PostHog accepted email #{message_id} without confirming its scheduled_at, so it may go out at " \
                 'another time.',
        fix: "Read what happened to the email with emails.get('#{message_id}') before you send it again: a send " \
             'with another idempotency_key makes a second email.'
      )
    end

    def warnings(entries)
      return [] unless entries.is_a?(Array)

      entries.grep(Hash).map do |entry|
        Warning.new(
          code: text(entry['code']) || 'warning',
          message: text(entry['detail']) || text(entry['message']) || '',
          fix: text(entry['fix'])
        )
      end
    end

    def parse_status_reply((status, payload, retry_after))
      fields = payload.is_a?(Hash) ? payload : {}
      raise reply_error(fields, status, retry_after) unless status.between?(200, 299)

      record = {
        id: text(fields['id']),
        status: text(fields['status']),
        created_at: timestamp(fields['created_at']),
        status_at: timestamp(fields['status_at'])
      }
      if record.value?(nil)
        raise EmailError.new(code: 'api_error', message: 'PostHog answered without an email status.',
                             status_code: status)
      end

      Status.new(**record, reason: text(fields['reason']))
    end

    def timestamp(value)
      text(value) && Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def reply_error(fields, status, retry_after)
      EmailError.new(
        code: text(fields['code']) || 'api_error',
        message: text(fields['detail']) || "PostHog answered HTTP #{status}.",
        status_code: status,
        why: text(fields['why']),
        fix: text(fields['fix']),
        docs_url: text(fields['docs_url']),
        field: text(fields['attr']),
        retry_after: retry_after
      )
    end

    def text(value)
      value if value.is_a?(String) && !value.empty?
    end
  end
end
