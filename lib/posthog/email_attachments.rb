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
    SUBJECT_BYTES_PER_ENCODED_WORD = 42
    ENCODED_WORD_BYTES = 75
    LIMIT = '10 files and 40 MB per email after Base64 encoding, about 29 MB of files'
    FIELDS = %w[filename content content_type content_id].freeze
    BASE64_LINE_WIDTHS = [60, 64, 76].freeze

    # One file to attach: its bytes, their SHA-256, and what the send says about it.
    Attachment = Struct.new(:bytes, :reference, :field, keyword_init: true) do
      def sha256
        @sha256 ||= Digest::SHA256.hexdigest(bytes)
      end
    end

    # @param files [Object] What the caller passed as `attachments`.
    # @param bodies [Array<String>] The email's HTML and text bodies, which count towards its size.
    # @param subject [String, nil] The email's subject, which counts towards its size.
    # @raise [EmailError] A file the client can't send, or more than one email can carry.
    def self.from(files, bodies, subject)
      raise invalid('attachments must be a list of files.', 'attachments') unless files.is_a?(Array)
      raise too_many_files if files.size > MAX_FILES

      new(files.each_with_index.map { |file, index| attachment(file, "attachments__#{index}") }, bodies, subject)
    end

    def self.attachment(file, field)
      unless file.is_a?(Hash)
        raise invalid("An attachment is a Hash with filename and content. Pass the file's bytes as its content.", field)
      end

      file = file.transform_keys(&:to_s).compact
      check_keys(file, field)
      bytes = file_bytes(file['content'], "#{field}__content")
      Attachment.new(bytes: bytes, field: field, reference: file.slice('filename', 'content_type', 'content_id'))
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
      raise ArgumentError if content.match?(/[\r\n]/) && !wrapped_base64?(content)

      content.delete("\r\n").unpack1('m0')
    rescue ArgumentError, EncodingError
      raise invalid("An attachment's content is text that isn't Base64. Pass the file's bytes, read with " \
                    'File.binread, or the file encoded as Base64.', field)
    end

    def self.wrapped_base64?(content)
      text = content.gsub("\r\n", "\n")
      return false if text.include?("\r")

      text = text.delete_suffix("\n")
      width = text.index("\n")
      return true if width.nil?

      text.ascii_only? && BASE64_LINE_WIDTHS.include?(width) && lines_of_width?(text, width)
    end

    def self.lines_of_width?(text, width)
      line_break = width
      while (next_break = text.index("\n", line_break + 1))
        return false unless next_break == line_break + width + 1

        line_break = next_break
      end
      (text.length - line_break - 1).between?(1, width)
    end

    def self.invalid(message, field)
      EmailError.new(code: 'invalid_attachment', message: message, field: field)
    end

    def self.too_many_files
      EmailError.new(code: 'too_many_attachments', field: 'attachments',
                     message: "An email carries at most #{MAX_FILES} files, so no email was sent.",
                     why: "An email carries at most #{MAX_FILES} files.",
                     fix: "Attach at most #{MAX_FILES} files, and link to any others from the email body.")
    end

    private_class_method :new, :attachment, :check_keys, :file_bytes, :raw_bytes, :base64_bytes,
                         :wrapped_base64?, :lines_of_width?, :invalid, :too_many_files

    def initialize(attachments, bodies, subject)
      @attachments = attachments
      check_size(bodies, subject)
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

    def check_size(bodies, subject)
      return if message_bytes(bodies, subject) <= MAX_MESSAGE_BYTES

      raise EmailError.new(
        code: 'message_too_large', field: 'attachments',
        message: 'The files are too large for one email, so no email was sent.',
        why: "PostHog's email provider takes emails up to 40 MB, and Base64 encoding makes each file about a " \
             'third larger.',
        fix: "Keep the email under #{LIMIT}: attach fewer or smaller files, or link to large files from the email " \
             'body.'
      )
    end

    def message_bytes(bodies, subject)
      files = @attachments.sum { |attachment| encoded_bytes(attachment.bytes.bytesize) }
      files + bodies.sum { |body| encoded_bytes(utf8_bytesize(body)) } + subject_bytes(subject) +
        HEADERS_AND_MIME_BOUNDARIES_BYTES
    end

    def subject_bytes(subject)
      return 0 unless subject.is_a?(String)

      (utf8_bytesize(subject) + SUBJECT_BYTES_PER_ENCODED_WORD - 1) / SUBJECT_BYTES_PER_ENCODED_WORD *
        ENCODED_WORD_BYTES
    end

    def utf8_bytesize(body)
      body.encoding == Encoding::BINARY ? body.bytesize : body.encode(Encoding::UTF_8).bytesize
    rescue EncodingError
      body.bytesize
    end

    def encoded_bytes(size)
      (((size + 2) / 3 * 4 * 78) + 75) / 76
    end
  end
end
