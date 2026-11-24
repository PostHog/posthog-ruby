# frozen_string_literal: true

require 'json'
require 'set'

require 'posthog/email_error'

module PostHog
  # The recipients of one {Emails#batch} call, split into requests, and what PostHog answered for each.
  #
  # @api private
  class EmailBatch
    MAX_RECIPIENTS = 100
    MAX_BODY_BYTES = 4 * 1024 * 1024
    UNCONFIRMED_CODES = %w[idempotency_key_in_flight delivery_unavailable api_error].freeze
    UNAVAILABLE_FIX = "Until batch sends are on for the project, send each email the batch didn't queue with " \
                      "emails.send and its recipient's idempotency_key."
    NOT_FOUND = {
      'code' => 'not_found',
      'detail' => 'PostHog found no batch send for this request, so no email was sent.',
      'why' => "The template doesn't exist, or batch sends are off for this project or this PostHog version.",
      'fix' => "Check template_id, or send each email the batch didn't queue with emails.send and its recipient's " \
               'idempotency_key.'
    }.freeze
    RESULT_DEFAULTS = { message_id: nil, replayed: false, error: nil, later_error: nil }.freeze
    private_constant :UNCONFIRMED_CODES, :UNAVAILABLE_FIX, :NOT_FOUND, :RESULT_DEFAULTS

    Member = Struct.new(:index, :to, :idempotency_key, :wire, keyword_init: true)
    # The recipients of one request. The body is built when the request goes out, so a large batch holds one at a
    # time.
    Chunk = Struct.new(:empty, :recipients, :indices, keyword_init: true) do
      def body
        "#{empty.delete_suffix(']}')}#{recipients.map(&:wire).join(',')}]}"
      end
    end

    attr_reader :chunks

    # @param shared [Hash] The batch's email without its recipients.
    # @param members [Array<Member>] Every recipient, with its JSON as the request carries it.
    # @param parse_warnings [#call] Turns a reply's warnings into {Emails::Warning}s.
    # @param reply_error [#call] Turns a refused reply into an {EmailError}.
    def initialize(shared, members, parse_warnings:, reply_error:)
      @members = members
      @parse_warnings = parse_warnings
      @reply_error = reply_error
      @results = Array.new(members.size)
      @warnings = []
      @maybe_queued = Set.new
      @chunks = split(JSON.generate(shared.merge(recipients: [])))
    end

    def lost(chunk)
      chunk.indices.each do |index|
        @maybe_queued << index
        message_id = @results[index]&.message_id
        set(index, 'unconfirmed', message_id: message_id, error: unconfirmed(message_id))
      end
    end

    def answer(chunk, (status, payload, retry_after))
      fields = payload.is_a?(Hash) ? payload : {}
      unless status.between?(200, 299)
        lost(chunk) if status >= 500
        raise response_error(fields, status, retry_after, chunk.indices)
      end

      slots = fields['results']
      unless slots.is_a?(Array) && slots.size == chunk.indices.size
        lost(chunk)
        raise EmailError.new(code: 'api_error', status_code: status,
                             message: 'PostHog answered the batch without a result for each recipient.')
      end
      chunk.indices.zip(slots) { |index, slot| settle(index, slot.is_a?(Hash) ? slot : {}) }
      @parse_warnings.call(fields['warnings']).each do |warning|
        @warnings << warning unless @warnings.include?(warning)
      end
    end

    def stop(position, error)
      later = error.status_code && error.status_code < 500 ? error : nil
      @chunks[position].indices.each do |index|
        if !@maybe_queued.include?(index)
          set(index, 'failed', error: error)
        elsif later
          earlier = @results[index]
          set(index, 'unconfirmed', message_id: earlier.message_id, error: earlier.error, later_error: later)
        end
      end
      skip_from(position + 1, EmailError.new(
                                code: 'not_attempted',
                                message: 'An earlier request of the batch failed, so the client sent nothing for ' \
                                         'this recipient.'
                              ))
    end

    def closed_at(position)
      error = EmailError.new(code: 'client_closed',
                             message: "The PostHog client is shut down, so the rest of the batch wasn't sent.")
      skip_from(position, error)
      error
    end

    def lost_keys
      @maybe_queued.sort.filter_map do |index|
        [index, @members[index].idempotency_key] if @results[index].message_id.nil?
      end
    end

    # A status read by key found the email. PostHog records a refusal before queueing, such as a suppressed
    # address, as a failed email, so only another status shows that PostHog accepted it.
    def found(index, status)
      if status.status == 'failed'
        earlier = @results[index]
        set(index, 'unconfirmed', message_id: status.id, error: earlier.error,
                                  later_error: earlier.later_error || failed_status(status))
        return
      end

      @maybe_queued.delete(index)
      set(index, 'queued', message_id: status.id)
    end

    def result
      Emails::BatchResult.new(results: @results.dup.freeze, warnings: @warnings.dup.freeze)
    end

    def failure(error)
      EmailBatchError.new(error, results: @results.dup.freeze, warnings: @warnings.dup.freeze)
    end

    private

    def split(empty)
      chunks = []
      current = []
      size = empty.bytesize
      @members.each do |member|
        if empty.bytesize + member.wire.bytesize > MAX_BODY_BYTES
          set(member.index, 'failed', error: recipient_too_large)
          next
        end
        added = member.wire.bytesize + (current.empty? ? 0 : 1)
        if !current.empty? && (current.size == MAX_RECIPIENTS || size + added > MAX_BODY_BYTES)
          chunks << chunk(empty, current)
          current = []
          size = empty.bytesize
          added = member.wire.bytesize
        end
        current << member
        size += added
      end
      chunks << chunk(empty, current) unless current.empty?
      chunks
    end

    def chunk(empty, members)
      Chunk.new(empty: empty, recipients: members, indices: members.map(&:index))
    end

    def settle(index, slot)
      message_id = text(slot['message_id'])
      if slot['error'].nil? && slot['status'] == 'queued' && message_id
        @maybe_queued.delete(index)
        set(index, 'queued', message_id: message_id, replayed: slot['replayed'] == true)
        return
      end

      answer = slot_error(slot['error'], message_id)
      if @maybe_queued.include?(index)
        earlier = @results[index]
        set(index, 'unconfirmed', message_id: message_id || earlier.message_id, error: earlier.error,
                                  later_error: answer)
      elsif UNCONFIRMED_CODES.include?(answer.code)
        @maybe_queued << index
        set(index, 'unconfirmed', message_id: message_id, error: answer)
      else
        set(index, 'failed', message_id: message_id, error: answer)
      end
    end

    def skip_from(position, error)
      @chunks.drop(position).each do |chunk|
        chunk.indices.each { |index| set(index, 'not_attempted', error: error) }
      end
    end

    def set(index, status, **fields)
      member = @members[index]
      identity = { index: index, to: member.to, idempotency_key: member.idempotency_key, status: status }
      @results[index] = Emails::BatchEmailResult.new(**RESULT_DEFAULTS, **identity, **fields)
    end

    def response_error(fields, status, retry_after, indices)
      answered = fields.compact
      answered['attr'] = recipients_field(answered['attr'], indices) if answered['attr'].is_a?(String)
      fields = status == 404 ? NOT_FOUND.merge(answered) : answered
      fields = fields.merge('fix' => UNAVAILABLE_FIX) if fields['code'] == 'batch_unavailable'
      @reply_error.call(fields, status, retry_after)
    end

    # PostHog names a recipient by its place in the request, and the caller knows it by its place in the batch.
    def recipients_field(attr, indices)
      parts = /\Arecipients__(\d+)(__.*)?\z/m.match(attr)
      return attr if parts.nil?

      position = parts[1]
      return 'recipients' if position.size > indices.size.to_s.size || position.to_i >= indices.size

      "recipients__#{indices[position.to_i]}#{parts[2]}"
    end

    def slot_error(error, message_id)
      unless error.is_a?(Hash)
        return EmailError.new(code: 'api_error', message_id: message_id,
                              message: 'PostHog answered without a readable result for this email, so it may still ' \
                                       'go out.')
      end

      code = text(error['code']) || 'api_error'
      status = error['status'].is_a?(Integer) ? error['status'] : nil
      # EmailError#message_id means PostHog may have accepted the email, so a refusal leaves it on the result only.
      EmailError.new(code: code, status_code: status, message_id: (message_id if UNCONFIRMED_CODES.include?(code)),
                     message: text(error['detail']) || "PostHog didn't queue this email: #{code}.")
    end

    def unconfirmed(message_id)
      EmailError.new(code: 'delivery_unavailable', message_id: message_id,
                     message: "PostHog didn't confirm this email, so it may still go out. Send it again with the " \
                              'same idempotency_key within 24 hours, so it goes out once.')
    end

    def failed_status(status)
      reason = text(status.reason)
      EmailError.new(code: reason || 'failed',
                     message: "PostHog's status of this email reads failed#{" (#{reason})" if reason}, so it may not " \
                              'have gone out.')
    end

    def recipient_too_large
      EmailError.new(code: 'content_too_large', field: 'recipients',
                     message: "This recipient's email is larger than one batch request takes, so it wasn't sent.",
                     fix: "Send this recipient's email with emails.send.")
    end

    def text(value)
      value if value.is_a?(String) && !value.empty?
    end
  end
end
