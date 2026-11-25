# frozen_string_literal: true

require 'json'

require 'posthog/email_error'

module PostHog
  # The recipients of one {Emails#batch} call, sent in one request, and what PostHog answered.
  #
  # @api private
  class EmailBatch
    MAX_RECIPIENTS = 100
    UNCONFIRMED_CODES = %w[idempotency_key_in_flight delivery_unavailable api_error].freeze
    RESEND_FIX = 'Send it again with the same idempotency_key within 24 hours of the first request that used it, so ' \
                 'it goes out once.'
    UNAVAILABLE_FIX = "Until batch sends are on for the project, send each email the batch didn't queue with " \
                      "emails.send and its recipient's idempotency_key."
    NOT_FOUND = {
      'code' => 'not_found',
      'detail' => 'PostHog found no batch send for this request, so no email was sent.',
      'why' => "The template doesn't exist, or batch sends are off for this project or this PostHog version.",
      'fix' => "Check template_id, or send each email the batch didn't queue with emails.send and its recipient's " \
               'idempotency_key.'
    }.freeze
    TOO_LARGE = {
      'code' => 'content_too_large',
      'detail' => 'PostHog refused the batch as too large, so no email was sent.',
      'fix' => 'Split the recipients into smaller batches.'
    }.freeze
    SMALLER_FIX = 'Make the email smaller, such as its template_data.'
    EARLIER_ATTEMPT = 'An earlier attempt of this batch may have queued this email, so it may still go out. ' \
                      'The last attempt ended with:'
    RESULT_DEFAULTS = { message_id: nil, replayed: false, error: nil }.freeze
    private_constant :UNCONFIRMED_CODES, :RESEND_FIX, :EARLIER_ATTEMPT, :UNAVAILABLE_FIX, :NOT_FOUND, :TOO_LARGE,
                     :SMALLER_FIX, :RESULT_DEFAULTS

    Member = Struct.new(:index, :to, :idempotency_key, :wire, keyword_init: true)

    attr_reader :body

    # @param shared [Hash] The batch's email without its recipients.
    # @param members [Array<Member>] Every recipient, with its JSON as the request carries it.
    # @param parse_warnings [#call] Turns a reply's warnings into {Emails::Warning}s.
    # @param reply_error [#call] Turns a refused reply into an {EmailError}.
    def initialize(shared, members, parse_warnings:, reply_error:)
      @members = members
      @parse_warnings = parse_warnings
      @reply_error = reply_error
      @warnings = []
      @maybe_queued = false
      @attempt_error = nil
      empty = JSON.generate(shared.merge(recipients: []))
      @body = "#{empty.delete_suffix(']}')}#{members.map(&:wire).join(',')}]}"
    end

    # @return [Emails::BatchResult] The result of an answer with a result for each recipient.
    # @raise [EmailError] PostHog refused the request, or answered without a result for each recipient.
    def answer((status, payload, retry_after))
      fields = payload.is_a?(Hash) ? payload : {}
      raise response_error(fields, status, retry_after) unless status.between?(200, 299)

      @warnings = @parse_warnings.call(fields['warnings']).uniq
      slots = fields['results']
      unless slots.is_a?(Array) && slots.size == @members.size
        raise EmailError.new(code: 'api_error', status_code: status, fix: RESEND_FIX,
                             message: 'PostHog answered the batch without a result for each recipient.')
      end

      results = @members.zip(slots).map { |member, slot| settle(member, slot.is_a?(Hash) ? slot : {}) }
      Emails::BatchResult.new(results: results.freeze, warnings: @warnings.dup.freeze)
    end

    # Remembers an attempt that failed, so a later attempt's refusal can't confirm what this one may have queued.
    def attempt_failed(error)
      @attempt_error = error
      @maybe_queued = true if maybe_queued?(error)
    end

    # Every recipient of a request that failed as a whole is `unconfirmed` when any attempt may have queued it, and
    # `failed` otherwise.
    def failure(error)
      # Only an attempt's error says what PostHog may have queued; the client raises client_closed without a request.
      refused = !(@attempt_error.equal?(error) && maybe_queued?(error))
      error = resend(error, earlier: true) if @maybe_queued && refused
      results = @members.map do |member|
        if @maybe_queued
          result(member, 'unconfirmed', error: resend(error))
        else
          result(member, 'failed', error: error)
        end
      end
      EmailBatchError.new(error, results: results.freeze, warnings: @warnings.dup.freeze)
    end

    private

    # The status, not the code, says whether PostHog may have queued the emails: a 4xx refused them, except a 409 for
    # keys still in flight. No answer, a 5xx and a 2xx without a result for each recipient leave them unknown.
    def maybe_queued?(error)
      status = error.status_code.to_i
      return true unless status.between?(400, 499)

      # PostHog's only other 409 is batch_unavailable, so a 409 whose body didn't name it may hold keys in flight.
      status == 409 && error.code != 'batch_unavailable'
    end

    def settle(member, slot)
      message_id = text(slot['message_id'])
      if slot['error'].nil? && slot['status'] == 'queued' && message_id
        return result(member, 'queued', message_id: message_id, replayed: slot['replayed'] == true)
      end

      answer = slot_error(slot['error'], message_id)
      if UNCONFIRMED_CODES.include?(answer.code)
        return result(member, 'unconfirmed', message_id: message_id, error: answer)
      elsif @maybe_queued
        # A refusal can't confirm an email that an earlier attempt of the request may have queued.
        return result(member, 'unconfirmed', message_id: message_id, error: resend(answer, earlier: true))
      end

      result(member, 'failed', message_id: message_id, error: answer)
    end

    def result(member, status, **fields)
      identity = { index: member.index, to: member.to, idempotency_key: member.idempotency_key, status: status }
      Emails::BatchEmailResult.new(**RESULT_DEFAULTS, **identity, **fields)
    end

    # A caller who follows PostHog's own advice without the key sends a second email. A refusal that follows an
    # attempt that may have queued the email can't say no email was sent, so its message says so first.
    def resend(error, earlier: false)
      return error if error.fix == RESEND_FIX

      message = earlier ? "#{EARLIER_ATTEMPT} #{error.message}" : error.message
      EmailError.new(code: error.code, message: message, status_code: error.status_code, why: error.why,
                     fix: RESEND_FIX, docs_url: error.docs_url, field: error.field, retry_after: error.retry_after)
    end

    def response_error(fields, status, retry_after)
      answered = fields.compact
      fields = if status == 404
                 NOT_FOUND.merge(answered)
               elsif status == 413
                 too_large(answered)
               else
                 answered
               end
      fields = fields.merge('fix' => UNAVAILABLE_FIX) if fields['code'] == 'batch_unavailable'
      @reply_error.call(fields, status, retry_after)
    end

    def too_large(answered)
      fields = TOO_LARGE.merge(answered.select { |_, value| text(value) })
      # One recipient can't be split, so only a smaller email gets through, whatever the reply advises.
      @members.size > 1 ? fields : fields.merge('fix' => SMALLER_FIX)
    end

    def slot_error(error, message_id)
      unless error.is_a?(Hash)
        return EmailError.new(code: 'api_error', message_id: message_id, fix: RESEND_FIX,
                              message: 'PostHog answered without a readable result for this email, so it may still ' \
                                       'go out.')
      end

      code = text(error['code']) || 'api_error'
      status = error['status'].is_a?(Integer) ? error['status'] : nil
      # EmailError#message_id means PostHog may have accepted the email, so a refusal leaves it on the result only.
      unconfirmed = UNCONFIRMED_CODES.include?(code)
      fallback = if unconfirmed
                   "PostHog couldn't confirm this email (#{code}), so it may still go out."
                 else
                   "PostHog didn't queue this email: #{code}."
                 end
      EmailError.new(code: code, status_code: status, message_id: (message_id if unconfirmed),
                     fix: (RESEND_FIX if unconfirmed), message: text(error['detail']) || fallback)
    end

    def text(value)
      value if value.is_a?(String) && !value.empty?
    end
  end
end
