# frozen_string_literal: true

module PostHog
  # PostHog did not queue the email, or the client could not tell whether it did.
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

    # @api private
    def initialize(code:, message:, status_code: nil, why: nil, fix: nil, docs_url: nil, field: nil, retry_after: nil)
      super(message)
      @name = self.class.name_for(status_code, code)
      @code = code
      @status_code = status_code
      @why = why
      @fix = fix
      @docs_url = docs_url
      @field = field
      @retry_after = retry_after
    end

    SDK_ERROR_NAMES = {
      'network_error' => 'service_unavailable',
      'invalid_attachment' => 'validation_error',
      'too_many_attachments' => 'validation_error',
      'message_too_large' => 'validation_error'
    }.freeze
    private_constant :SDK_ERROR_NAMES

    # @api private
    def self.name_for(status_code, code)
      return 'missing_api_key' if code == 'missing_secret_key' || status_code == 401
      return status_code.to_i >= 500 ? 'service_unavailable' : 'application_error' if code == 'attachment_upload_failed'
      return SDK_ERROR_NAMES.fetch(code, 'application_error') if status_code.nil?

      case status_code
      when 400 then 'validation_error'
      when 403 then 'invalid_permission'
      when 404 then 'not_found'
      when 409 then code == 'template_outdated' ? 'validation_error' : 'concurrent_idempotent_requests'
      when 422 then code == 'idempotency_key_reused' ? 'invalid_idempotent_request' : 'validation_error'
      when 429 then code == 'quota_limited' ? 'monthly_quota_exceeded' : 'rate_limit_exceeded'
      when 503 then 'service_unavailable'
      else 'application_error'
      end
    end
  end
end
