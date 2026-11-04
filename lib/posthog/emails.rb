# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'time'
require 'uri'
require 'zlib'

require 'posthog/email_error'
require 'posthog/logging'
require 'posthog/utils'

module PostHog
  # Sends transactional email, from an email template made in PostHog or from content your code rendered,
  # and reads the status of each email sent. Reach it through {Client#emails}.
  #
  # A send needs the client's `secret_key`, a project secret API key (`phs_...`) with the `hog_flow:write` scope.
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
    SEND_KEY_NEEDED = 'Sending email needs secret_key, a project secret API key with the hog_flow:write scope.'
    READ_KEY_NEEDED = 'Reading an email status needs secret_key, a project secret API key with the hog_flow:read ' \
                      'or hog_flow:write scope.'
    TEMPLATE_FORM_WHY = 'A template made in PostHog sets its own sender, subject and content, and follows the ' \
                        "project's engagement setting."
    CODE_FORM_WHY = 'A send with template_key takes its content from your code.'
    TEMPLATE_FIELDS = %i[template_data].freeze
    CODE_FIELDS = %i[subject html text from reply_to cc bcc attachments capture_engagement].freeze
    ATTACHMENT_FIELDS = %w[filename content content_type content_id].freeze
    BASE64_PATTERN = %r{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\z}
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, Zlib::Error
    ].freeze
    private_constant :SEND_PATH, :STATUS_PATH, :US_APP_HOST, :EU_APP_HOST, :CLOUD_APP_HOSTS,
                     :MAX_RETRY_DELAY_SECONDS, :UUID_PATTERN, :IDEMPOTENCY_KEY_PATTERN, :TEMPLATE_KEY_PATTERN,
                     :HEADER_TOKEN_PATTERN, :SEND_KEY_NEEDED, :READ_KEY_NEEDED, :TEMPLATE_FORM_WHY,
                     :CODE_FORM_WHY, :TEMPLATE_FIELDS, :CODE_FIELDS, :ATTACHMENT_FIELDS, :BASE64_PATTERN,
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
    # @param attachments [Array<Hash>] Code form: files sent with the email, at most 10 and 512 KB in total. Each
    #   file is a Hash with:
    #   - +filename+ [String] the name the recipient sees, such as `invoice.pdf`;
    #   - +content+ [String, Array<Integer>] the file's bytes, as a binary String such as `File.binread(path)`
    #     returns or as a list of byte values, which the client encodes as Base64. Any other String is taken as the
    #     file already Base64 encoded. PostHog can't fetch a file from a path or URL;
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
    # @return [SendResult] The queued email.
    # @raise [EmailError] PostHog did not queue the email, or the client could not tell whether it did.
    #   {EmailError#code} is `invalid_attachment`, before any request, for a file the client can't send.
    # @raise [ArgumentError] An argument has the wrong type or format, or the call mixes the two forms.
    def send(
      to:, template_id: nil, template_data: nil, template_key: nil, subject: nil, html: nil, text: nil, from: nil,
      reply_to: nil, cc: nil, bcc: nil, attachments: nil, capture_engagement: nil, distinct_id: nil,
      idempotency_key: nil, max_retries: nil
    )
      fields = {
        template_data: template_data, subject: subject, html: html, text: text, from: from, reply_to: reply_to,
        cc: cc, bcc: bcc, attachments: attachments, capture_engagement: capture_engagement
      }.compact
      check_recipient(to, distinct_id, idempotency_key, max_retries)
      payload = content(template_id, template_key, fields).merge(to: to)
      payload[:distinct_id] = distinct_id unless distinct_id.nil?
      body = JSON.generate(payload)
      headers = { 'Content-Type' => 'application/json', 'Idempotency-Key' => idempotency_key || SecureRandom.uuid }

      result = call('no email was sent', SEND_KEY_NEEDED) do |secret_key|
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
      # An empty list goes out as no list, because a PostHog version without the field refuses it even empty.
      %i[cc bcc].each do |name|
        list = addresses(name, fields[name]) if fields.key?(name)
        code[name] = list unless list.nil? || list.empty?
      end
      files = attachment_list(fields[:attachments]) if fields.key?(:attachments)
      code[:attachments] = files unless files.nil? || files.empty?
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

    def attachment_list(files)
      raise invalid_attachment('attachments must be a list of files.', 'attachments') unless files.is_a?(Array)

      files.each_with_index.map { |file, index| attachment(file, "attachments__#{index}") }
    end

    def attachment(file, field)
      unless file.is_a?(Hash)
        raise invalid_attachment("An attachment is a Hash with filename and content. Pass the file's bytes as its " \
                                 'content.', field)
      end

      file = file.transform_keys(&:to_s).compact
      if file.key?('path')
        raise invalid_attachment("PostHog can't fetch an attachment from a path or URL. Read the file with " \
                                 'File.binread and pass it as content instead.', "#{field}__path")
      end
      unknown = file.keys.find { |key| !ATTACHMENT_FIELDS.include?(key) }
      if unknown
        raise invalid_attachment("An attachment takes filename, content, content_type and content_id, not #{unknown}.",
                                 "#{field}__#{unknown}")
      end

      %w[filename content_type content_id].each do |name|
        next if name != 'filename' && !file.key?(name)
        next if file[name].is_a?(String)

        raise invalid_attachment("An attachment's #{name} must be a String.", "#{field}__#{name}")
      end
      file.merge('content' => base64_content(file['content'], "#{field}__content"))
    end

    # A binary String or a list of byte values is the file itself. Any other String is the file already in Base64:
    # Ruby has one String type for bytes and text, and File.binread returns a binary one.
    def base64_content(content, field)
      bytes = file_bytes(content)
      return [bytes].pack('m0') if bytes
      return content if content.is_a?(String) && BASE64_PATTERN.match?(content)

      if content.is_a?(String)
        raise invalid_attachment("An attachment's content is text that isn't Base64. Pass the file's bytes, read " \
                                 'with File.binread, or the file encoded as Base64.', field)
      end
      raise invalid_attachment('An attachment needs content: the bytes File.binread returns, a list of byte values, ' \
                               'or the file encoded as Base64.', field)
    end

    def file_bytes(content)
      return content if content.is_a?(String) && content.encoding == Encoding::BINARY
      return unless content.is_a?(Array) && content.all? { |byte| byte.is_a?(Integer) && byte.between?(0, 255) }

      content.pack('C*')
    end

    # The message never holds the file's content, so the error is safe to log.
    def invalid_attachment(message, field)
      EmailError.new(code: 'invalid_attachment', message: message, field: field)
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
      when 429 then error.code != 'quota_limited'
      else error.status_code == 503
      end
    end

    def request(request, uri, secret_key, headers, body = nil)
      request['Authorization'] = "Bearer #{secret_key}"
      request['Accept'] = 'application/json'
      request['User-Agent'] = @user_agent if @user_agent
      request['X-PostHog-Migrated-From'] = @migrated_from if @migrated_from
      headers.each { |name, value| request[name] = value }
      request.body = body if body

      head = nil
      response = Net::HTTP.start(uri.hostname, uri.port, connection_options(uri)) do |http|
        http.request(request) { |started| head = started }
      end
      [response.code.to_i, parse_json(response.body), parse_retry_after(response['Retry-After'])]
    rescue *NETWORK_ERRORS
      # A refusal whose body broke off still carries its status and Retry-After. An acceptance whose body broke off
      # has no message ID, so it retries with the same idempotency key.
      return [head.code.to_i, nil, parse_retry_after(head['Retry-After'])] if head && !head.is_a?(Net::HTTPSuccess)

      raise EmailError.new(code: 'network_error', message: 'The request to PostHog failed.')
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
