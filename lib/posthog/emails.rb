# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'time'
require 'uri'
require 'zlib'

require 'posthog/email_attachments'
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
  class Emails
    include PostHog::Logging
    include PostHog::Utils

    # The queued email. A result means PostHog queued the email, not that it was delivered.
    #
    # @!attribute [r] id
    #   @return [String] The queued email's message ID.
    # @!attribute [r] replayed
    #   @return [Boolean] Whether PostHog had already accepted this idempotency key and returned the first result.
    # @!attribute [r] warnings
    #   @return [Array<Warning>]
    SendResult = Struct.new(:id, :replayed, :warnings, keyword_init: true)

    # A warning PostHog returned with a queued email.
    Warning = Struct.new(:code, :message, :fix, keyword_init: true)

    # What happened to an email that {Emails#send} queued.
    #
    # @!attribute [r] status
    #   @return [String] `queued`, `sent`, `failed`, `delivered`, `bounced` or `complained`. Later SDK versions
    #     can see values this list does not have yet.
    # @!attribute [r] reason
    #   @return [String, nil] Why a failed email was not sent, such as `recipient_suppressed`, or the bounce type
    #     of a bounced email: `hard`, `soft` or `unknown`.
    Status = Struct.new(:id, :status, :created_at, :status_at, :reason, keyword_init: true)

    SEND_PATH = '/api/projects/@current/messaging/send/email/'
    UPLOADS_PATH = '/api/projects/@current/messaging/attachments/uploads/'
    STATUS_PATH = '/api/projects/@current/messaging/emails/%<message_id>s/'
    US_APP_HOST = 'https://us.posthog.com'
    EU_APP_HOST = 'https://eu.posthog.com'
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
    INTEGRATION_PATTERN = %r{\A[a-z0-9-]{1,40}/[0-9A-Za-z.+-]{1,40}\z}
    JSON_CONTENT = { 'Content-Type' => 'application/json' }.freeze
    SEND_KEY_NEEDED = 'Sending email needs secret_key, a project secret API key with the ' \
                      'transactional_email:write scope.'
    READ_KEY_NEEDED = 'Reading an email status needs secret_key, a project secret API key with the ' \
                      'transactional_email:read or transactional_email:write scope.'
    TEMPLATE_FORM_WHY = 'A template made in PostHog sets its own sender, subject and content, and follows the ' \
                        "project's engagement setting."
    CODE_FORM_WHY = 'A send with template_key takes its content from your code.'
    TEMPLATE_FIELDS = %i[template_data].freeze
    CODE_FIELDS = %i[subject html text from reply_to cc bcc attachments capture_engagement].freeze
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, Zlib::Error
    ].freeze
    private_constant :SEND_PATH, :UPLOADS_PATH, :STATUS_PATH, :US_APP_HOST, :EU_APP_HOST, :CLOUD_APP_HOSTS,
                     :MAX_RETRY_DELAY_SECONDS, :UUID_PATTERN, :IDEMPOTENCY_KEY_PATTERN, :TEMPLATE_KEY_PATTERN,
                     :HEADER_TOKEN_PATTERN, :INTEGRATION_PATTERN, :JSON_CONTENT, :SEND_KEY_NEEDED,
                     :READ_KEY_NEEDED, :TEMPLATE_FORM_WHY, :CODE_FORM_WHY, :TEMPLATE_FIELDS, :CODE_FIELDS,
                     :NETWORK_ERRORS

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
    # @param capture_engagement [Boolean] Code form: whether PostHog captures the email's opens and clicks as events
    #   of the recipient. Defaults to +true+. A project whose admin turned engagement capture off captures nothing.
    # @param distinct_id [String] The recipient's distinct ID in your product. The email's events go to this
    #   person. Without it, they go to a person whose distinct ID is the email address.
    # @param idempotency_key [String] 1 to 255 visible ASCII characters. A send with a key PostHog has already
    #   accepted queues nothing and returns the first send's result. Without it, the client makes a UUID that covers
    #   its own retries. Pass a key derived from what the email is for, such as `welcome:user_123`, when a job runner
    #   retries the send.
    # @param max_retries [Integer] Overrides the client's `email_request_max_retries` for this send. +0+ turns
    #   retries off.
    # @param integration [String] For a library that sends on the app's behalf, such as a mailer adapter: its name
    #   and version, such as `action-mailer/3.14.0`, sent as the `X-PostHog-Integration` header. The name is lowercase
    #   letters, digits and hyphens; the version is letters, digits, dots, plus signs and hyphens; each at most 40.
    # @return [SendResult] The queued email.
    # @raise [EmailError] PostHog did not queue the email, or the client could not tell whether it did.
    #   Before any request, {EmailError#code} is `invalid_attachment` for a file the client can't send,
    #   `too_many_attachments` for more than 10 files, and `message_too_large` for files too large for one email.
    #   It is `attachment_upload_failed` when file storage refused an upload, and `not_found` with
    #   {EmailError#field} `attachments` when PostHog has no upload route for this project. Unless `app_host` is
    #   an http URL, an upload URL without https raises `api_error` on the file's field, such as
    #   `attachments__0`, before any file goes out. No email was sent.
    # @raise [ArgumentError] An argument has the wrong type or format, or the call mixes the two forms.
    def send(
      to:, template_id: nil, template_data: nil, template_key: nil, subject: nil, html: nil, text: nil, from: nil,
      reply_to: nil, cc: nil, bcc: nil, attachments: nil, capture_engagement: nil, distinct_id: nil,
      idempotency_key: nil, max_retries: nil, integration: nil
    )
      fields = {
        template_data: template_data, subject: subject, html: html, text: text, from: from, reply_to: reply_to,
        cc: cc, bcc: bcc, attachments: attachments, capture_engagement: capture_engagement
      }.compact
      check_recipient(to, distinct_id, idempotency_key, max_retries)
      check_integration(integration)
      payload = content(template_id, template_key, fields).merge(to: to)
      files = EmailAttachments.from(fields.fetch(:attachments, []), bodies_with_derived_text(fields), fields[:subject])
      payload[:attachments] = files.references unless files.empty?
      payload[:distinct_id] = distinct_id unless distinct_id.nil?
      body = JSON.generate(payload)
      headers = { 'Content-Type' => 'application/json', 'Idempotency-Key' => idempotency_key || SecureRandom.uuid }
      headers['X-PostHog-Integration'] = integration if integration

      result = call('no email was sent', SEND_KEY_NEEDED) do |secret_key|
        upload(files, secret_key, max_retries || @max_retries) unless files.empty?
        uri = URI(@app_host + SEND_PATH)
        with_retries(max_retries || @max_retries) do
          parse_send_reply(request(Net::HTTP::Post.new(uri), uri, secret_key, headers, body))
        end
      end
      result.warnings.each { |warning| logger.warn("PostHog email warning #{warning.code}: #{warning.message}") }
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

    def check_integration(integration)
      return if integration.nil? || (integration.is_a?(String) && INTEGRATION_PATTERN.match?(integration))

      raise ArgumentError, "integration must be a name and version, such as 'action-mailer/3.14.0'."
    end

    def nonempty_string?(value)
      value.is_a?(String) && !value.strip.empty?
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
      unless [nil, true, false].include?(fields[:capture_engagement])
        raise ArgumentError, 'capture_engagement must be true or false.'
      end

      code = fields.slice(:subject, :html, :text, :from).merge(template_key: template_key)
      code[:reply_to] = addresses(:reply_to, fields[:reply_to]) if fields.key?(:reply_to)
      %i[cc bcc].each do |name|
        list = fields.key?(name) ? addresses(name, fields[name]) : []
        code[name] = list unless list.empty?
      end
      code[:capture_engagement] = fields.fetch(:capture_engagement, true)
      code
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
        yield
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

    def request(request, uri, secret_key, headers, body = nil)
      request['Authorization'] = "Bearer #{secret_key}"
      request['Accept'] = 'application/json'
      request['User-Agent'] = @user_agent if @user_agent
      request['X-PostHog-Migrated-From'] = @migrated_from if @migrated_from
      status, answer, retry_after = exchange(request, uri, headers, body)
      [status, parse_json(answer), retry_after]
    end

    def exchange(request, uri, headers, body)
      headers.each { |name, value| request[name] = value }
      request.body = body if body

      head = nil
      response = Net::HTTP.start(uri.hostname, uri.port, connection_options(uri)) do |http|
        http.request(request) { |started| head = started }
      end
      [response.code.to_i, response.body, parse_retry_after(response['Retry-After'])]
    rescue *NETWORK_ERRORS
      # A reply whose body broke off retries with the same idempotency key, after its Retry-After when it sent one.
      raise EmailError.new(code: 'network_error', message: 'The request to PostHog failed.',
                           retry_after: head && parse_retry_after(head['Retry-After']))
    end

    def connection_options(uri)
      options = {
        use_ssl: uri.scheme == 'https', open_timeout: @timeout, read_timeout: @timeout, write_timeout: @timeout,
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

    def parse_send_reply((status, payload, retry_after))
      fields = payload.is_a?(Hash) ? payload : {}
      raise reply_error(fields, status, retry_after) unless status.between?(200, 299)

      id = text(fields['message_id'])
      unless id
        raise EmailError.new(code: 'api_error', message: 'PostHog answered without a message ID.',
                             status_code: status)
      end

      SendResult.new(id: id, replayed: fields['replayed'] == true, warnings: warnings(fields['warnings']))
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
