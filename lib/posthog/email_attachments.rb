# frozen_string_literal: true

require 'digest'

require 'posthog/email_error'

module PostHog
  # The files of one send: each file's bytes and SHA-256, checked against the limits of one email before any request.
  #
  # @api private
  class EmailAttachments
    MAX_FILES = 10
    MAX_MESSAGE_BYTES = 40_000_000
    HEADERS_AND_MIME_BOUNDARIES_BYTES = 64 * 1024
    LIMIT = '10 files and 40 MB per email after Base64 encoding, about 29 MB of files'
    FIELDS = %w[filename content content_type content_id].freeze
    BASE64_PATTERN = %r{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\z}

    # One file to attach: its bytes, their SHA-256, and what the send says about it.
    Attachment = Struct.new(:bytes, :sha256, :reference, :field, keyword_init: true)

    # @param files [Object] What the caller passed as `attachments`.
    # @param bodies [Array<String>] The email's HTML and text bodies, which count towards its size.
    # @raise [EmailError] A file the client can't send, or more than one email can carry.
    def self.from(files, bodies)
      raise invalid('attachments must be a list of files.', 'attachments') unless files.is_a?(Array)

      new(files.each_with_index.map { |file, index| attachment(file, "attachments__#{index}") }, bodies)
    end

    def self.attachment(file, field)
      unless file.is_a?(Hash)
        raise invalid("An attachment is a Hash with filename and content. Pass the file's bytes as its content.", field)
      end

      file = file.transform_keys(&:to_s).compact
      check_keys(file, field)
      bytes = file_bytes(file['content'], "#{field}__content")
      Attachment.new(bytes: bytes, sha256: Digest::SHA256.hexdigest(bytes), field: field,
                     reference: file.slice('filename', 'content_type', 'content_id'))
    end

    def self.check_keys(file, field)
      if file.key?('path')
        raise invalid("PostHog can't fetch an attachment from a path or URL. Read the file with File.binread and " \
                      'pass it as content instead.', "#{field}__path")
      end
      unknown = file.keys.find { |key| !FIELDS.include?(key) }
      if unknown
        raise invalid("An attachment takes filename, content, content_type and content_id, not #{unknown}.",
                      "#{field}__#{unknown}")
      end

      %w[filename content_type content_id].each do |name|
        next if name != 'filename' && !file.key?(name)
        next if file[name].is_a?(String)

        raise invalid("An attachment's #{name} must be a String.", "#{field}__#{name}")
      end
    end

    def self.file_bytes(content, field)
      bytes = raw_bytes(content) || base64_bytes(content, field)
      raise invalid("An attachment can't be empty. Pass the file's bytes as its content.", field) if bytes.empty?

      bytes
    end

    def self.raw_bytes(content)
      return content if content.is_a?(String) && content.encoding == Encoding::BINARY
      return unless content.is_a?(Array) && content.all? { |byte| byte.is_a?(Integer) && byte.between?(0, 255) }

      content.pack('C*')
    end

    def self.base64_bytes(content, field)
      unless content.is_a?(String)
        raise invalid('An attachment needs content: the bytes File.binread returns, a list of byte values, or the ' \
                      'file encoded as Base64.', field)
      end
      return content.unpack1('m0') if content.ascii_only? && BASE64_PATTERN.match?(content)
      return content.unpack1('m') if encode64_layout?(content)

      raise invalid("An attachment's content is text that isn't Base64. Pass the file's bytes, read with " \
                    'File.binread, or the file encoded as Base64.', field)
    end

    def self.encode64_layout?(content)
      content.ascii_only? && content.include?("\n") && [content.unpack1('m')].pack('m') == content
    end

    def self.invalid(message, field)
      EmailError.new(code: 'invalid_attachment', message: message, field: field)
    end

    private_class_method :new, :attachment, :check_keys, :file_bytes, :raw_bytes, :base64_bytes,
                         :encode64_layout?, :invalid

    def initialize(attachments, bodies)
      @attachments = attachments
      check_fits(bodies)
    end

    def empty?
      @attachments.empty?
    end

    # @return [Array<Hash>] The files as the send names them.
    def references
      @attachments.map { |attachment| { 'sha256' => attachment.sha256 }.merge(attachment.reference) }
    end

    # @return [Array<Attachment>] Each distinct file once, in the order the caller gave them.
    def distinct
      @attachments.uniq(&:sha256)
    end

    private

    def check_fits(bodies)
      if @attachments.size > MAX_FILES
        raise refusal('too_many_attachments', "An email carries at most #{MAX_FILES} files, so no email was sent.",
                      why: "An email carries at most #{MAX_FILES} files.",
                      fix: "Attach at most #{MAX_FILES} files, and link to any others from the email body.")
      end
      return if message_bytes(bodies) <= MAX_MESSAGE_BYTES

      raise refusal('message_too_large', 'The files are too large for one email, so no email was sent.',
                    why: "PostHog's email provider takes emails up to 40 MB, and Base64 encoding makes each file " \
                         'about a third larger.',
                    fix: "Keep the email under #{LIMIT}: attach fewer or smaller files, or link to large files " \
                         'from the email body.')
    end

    def message_bytes(bodies)
      files = @attachments.sum { |attachment| encoded_bytes(attachment.bytes.bytesize) }
      files + bodies.sum(&:bytesize) + HEADERS_AND_MIME_BOUNDARIES_BYTES
    end

    def encoded_bytes(size)
      (((size + 2) / 3 * 4 * 78) + 75) / 76
    end

    def refusal(code, message, why:, fix:)
      EmailError.new(code: code, message: message, field: 'attachments', why: why, fix: fix)
    end
  end
end
