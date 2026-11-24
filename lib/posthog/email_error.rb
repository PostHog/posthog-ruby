# frozen_string_literal: true

module PostHog
  # PostHog did not queue the email, or the client could not tell whether it did. An error with a {#message_id}
  # is the exception: PostHog accepted that email, which may still go out, so read it with {Emails#get} before you
  # send again.
  #
  # Branch on {#code}, PostHog's stable error code, or on {#name}, a coarse category of the failure.
  # The message never contains the secret key or the request body.
  class EmailError < StandardError
    # @return [String] A coarse category of the failure, such as `validation_error`, `rate_limit_exceeded`
    #   or `service_unavailable`.
    attr_reader :name
    # @return [String] PostHog's error code, such as `quota_limited`, or an SDK code such as `network_error`.
    attr_reader :code
    # @return [Integer, nil] The HTTP status, when PostHog answered, or file storage's for `attachment_upload_failed`.
    attr_reader :status_code
    # @return [String, nil] Why PostHog refused the email.
    attr_reader :why
    # @return [String, nil] How to fix the request.
    attr_reader :fix
    # @return [String, nil] A link to the docs for this error.
    attr_reader :docs_url
    # @return [String, nil] The request field the error is about, when PostHog named one.
    attr_reader :field
    # @return [Float, nil] How long PostHog asked the client to wait before it sends again, in seconds.
    attr_reader :retry_after
    # @return [String, nil] The message ID of an email PostHog accepted although the call failed, such as an email
    #   whose `schedule_not_confirmed` means it may go out at another time. Read its status with {Emails#get}.
    attr_reader :message_id
    # @return [Array<Emails::Warning>] PostHog's warnings about the emails it accepted although the call failed, each
    #   once, such as those of a batch's requests that went out. The client logs warnings only for a call that
    #   succeeds.
    attr_reader :warnings

    # @api private
    def initialize(code:, message:, status_code: nil, why: nil, fix: nil, docs_url: nil, field: nil, retry_after: nil,
                   message_id: nil, warnings: [])
      super(message)
      @name = self.class.name_for(status_code, code)
      @code = code
      @status_code = status_code
      @why = why
      @fix = fix
      @docs_url = docs_url
      @field = field
      @retry_after = retry_after
      @message_id = message_id
      @warnings = warnings.dup.freeze
    end

    SDK_ERROR_NAMES = {
      'network_error' => 'service_unavailable',
      'invalid_attachment' => 'validation_error',
      'too_many_attachments' => 'validation_error',
      'message_too_large' => 'validation_error',
      'scheduling_requires_cloud' => 'validation_error',
      'delivery_unavailable' => 'service_unavailable',
      'content_too_large' => 'validation_error'
    }.freeze
    # A 409 PostHog answers before it takes the request, so no idempotency key is in flight.
    VALIDATION_CONFLICTS = %w[template_outdated batch_unavailable].freeze
    private_constant :SDK_ERROR_NAMES, :VALIDATION_CONFLICTS

    # @api private
    def self.name_for(status_code, code)
      return status_code.to_i >= 500 ? 'service_unavailable' : 'application_error' if code == 'attachment_upload_failed'
      return 'missing_api_key' if code == 'missing_secret_key' || status_code == 401
      return SDK_ERROR_NAMES.fetch(code, 'application_error') if status_code.nil?

      case status_code
      when 400 then 'validation_error'
      when 403 then 'invalid_permission'
      when 404 then 'not_found'
      when 409 then VALIDATION_CONFLICTS.include?(code) ? 'validation_error' : 'concurrent_idempotent_requests'
      when 422 then code == 'idempotency_key_reused' ? 'invalid_idempotent_request' : 'validation_error'
      when 429 then code == 'quota_limited' ? 'monthly_quota_exceeded' : 'rate_limit_exceeded'
      when 503 then 'service_unavailable'
      else 'application_error'
      end
    end
  end

  # The request of {Emails#batch} failed as a whole.
  #
  # The other fields describe its error. {#results} holds every recipient: `unconfirmed` where PostHog may have queued
  # them in any attempt, such as after a lost answer or while it held their keys, and `failed` otherwise.
  class EmailBatchError < EmailError
    # @return [Array<Emails::BatchEmailResult>] One result per recipient, in the order of the batch's recipients.
    attr_reader :results

    # @api private
    def initialize(error, results:, warnings:)
      super(code: error.code, message: error.message, status_code: error.status_code, why: error.why, fix: error.fix,
            docs_url: error.docs_url, field: error.field, retry_after: error.retry_after, message_id: error.message_id,
            warnings: warnings)
      @results = results
    end
  end
end
