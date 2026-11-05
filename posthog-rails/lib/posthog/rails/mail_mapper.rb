# frozen_string_literal: true

require 'posthog/rails/delivery_errors'

module PostHog
  module Rails
    # Turns one Mail::Message into the arguments of one {PostHog::Emails#send}, or refuses it with
    # {UnsupportedMailError} when PostHog can't carry part of it. It reads the message and nothing else.
    #
    # @api private
    class MailMapper
      INTEGRATION_NAME = 'action-mailer'
      TEMPLATE_KEY_PATTERN = /\A[a-zA-Z0-9_-]{1,400}\z/
      MAPPED_HEADERS = %w[from to cc bcc reply-to subject].freeze
      IGNORED_HEADERS = %w[message-id date mime-version x-mailer return-path sender].freeze
      OPTION_HEADERS = {
        'x-posthog-distinct-id' => :distinct_id,
        'x-posthog-template-key' => :template_key,
        'x-posthog-idempotency-key' => :idempotency_key,
        'x-posthog-capture-engagement' => :capture_engagement
      }.freeze
      TEMPLATE_HEADER = 'x-posthog-template-id'
      NORMAL_PRIORITY = { 'x-priority' => /\A3\b/, 'priority' => /\Anormal\z/i, 'importance' => /\Anormal\z/i }.freeze
      private_constant :TEMPLATE_KEY_PATTERN, :MAPPED_HEADERS, :IGNORED_HEADERS, :OPTION_HEADERS, :TEMPLATE_HEADER,
                       :NORMAL_PRIORITY

      # @param default_template_key [String, nil] The key for mail that sets none and has no mailer name.
      def initialize(default_template_key: nil)
        @default_template_key = default_template_key
      end

      # @param mail [Mail::Message]
      # @param derived_template_key [String, nil] The mailer's own name for the mail, such as `user_mailer-welcome`.
      # @return [Hash] Keyword arguments for {PostHog::Emails#send}.
      # @raise [UnsupportedMailError] PostHog can't send part of the message.
      def map(mail, derived_template_key: nil)
        options = posthog_options(mail)
        recipient = single_recipient(mail)
        check_envelope(mail, recipient)
        {
          to: recipient,
          from: sender(mail),
          reply_to: mail.reply_to,
          cc: mail.cc,
          bcc: mail.bcc,
          subject: mail.subject,
          template_key: template_key(options[:template_key], derived_template_key),
          **content(mail),
          **options.slice(:distinct_id, :idempotency_key, :capture_engagement)
        }.compact
      end

      private

      def posthog_options(mail)
        mail.header.fields.each_with_object({}) do |field, options|
          name = field.name.downcase
          value = field.value.to_s
          next if MAPPED_HEADERS.include?(name) || IGNORED_HEADERS.include?(name) || name.start_with?('content-')
          next if NORMAL_PRIORITY.key?(name) && NORMAL_PRIORITY[name].match?(value.strip)

          options[OPTION_HEADERS.fetch(name) { refuse_header(name, field.name) }] = option_value(name, value)
        end
      end

      def refuse_header(name, header)
        refuse('template_unsupported', 'Action Mailer sends rendered mail, not a template made in PostHog') if
          name == TEMPLATE_HEADER
        refuse('unsupported_priority', "PostHog sends every email at normal priority, so it can't send #{header}") if
          NORMAL_PRIORITY.key?(name)
        refuse('unsupported_header', "PostHog can't send the #{header} header")
      end

      def option_value(name, value)
        return value unless name == 'x-posthog-capture-engagement'
        return value == 'true' if %w[true false].include?(value)

        refuse('unsupported_header', 'X-PostHog-Capture-Engagement must be true or false')
      end

      def single_recipient(mail)
        recipients = Array(mail.to)
        return recipients.first if recipients.one?

        refuse('multiple_to', "PostHog sends each email to exactly one To address, and this one has #{recipients.size}")
      end

      def sender(mail)
        addresses = mail[:from]&.addrs || []
        refuse('unsupported_header', 'PostHog sends from one From address') if addresses.size > 1
        address = addresses.first
        return if address.nil?

        address.display_name ? "#{address.display_name} <#{address.address}>" : address.address
      end

      def check_envelope(mail, recipient)
        sender_matches = mail.smtp_envelope_from == Array(mail.from).first
        recipients_match = Array(mail.smtp_envelope_to).sort == [recipient, *mail.cc, *mail.bcc].sort
        return if sender_matches && recipients_match

        refuse('envelope_mismatch', 'PostHog sends to the To, Cc and Bcc addresses from the From address only')
      end

      def template_key(explicit, derived)
        unless explicit.nil?
          return explicit if TEMPLATE_KEY_PATTERN.match?(explicit)

          refuse('invalid_template_key', 'X-PostHog-Template-Key can only have letters, digits, hyphens and ' \
                                         'underscores, at most 400')
        end

        sanitized(derived) || @default_template_key || INTEGRATION_NAME
      end

      def sanitized(key)
        key = key.to_s.gsub(/[^a-zA-Z0-9_-]+/, '-').gsub(/\A-+|-+\z/, '')[0, 400]
        key unless key.empty?
      end

      def content(mail)
        leaves = mail.multipart? ? mail.all_parts.reject(&:multipart?) : [mail]
        files, bodies = leaves.partition(&:attachment?)
        content = bodies.each_with_object({}) do |part, by_kind|
          kind = body_kind(part)
          refuse('unsupported_part', "PostHog sends one HTML and one text body, so it can't send #{part.mime_type}") if
            kind.nil? || by_kind.key?(kind)
          by_kind[kind] = part.decoded
        end
        files.empty? ? content : content.merge(attachments: files.map { |file| attachment(file) })
      end

      def body_kind(part)
        case part.mime_type
        when 'text/html' then :html
        when 'text/plain', nil then :text
        end
      end

      def attachment(part)
        file = { filename: part.filename, content_type: part.mime_type, content: part.body.decoded.b }
        return file unless part.inline?

        refuse('inline_without_cid', "The inline attachment #{part.filename} has no Content-ID") unless
          part.has_content_id?
        file.merge(content_id: part.cid)
      end

      def refuse(code, detail)
        raise UnsupportedMailError.new(refusal: code, detail: detail)
      end
    end
    private_constant :MailMapper
  end
end
