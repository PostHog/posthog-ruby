# frozen_string_literal: true

module PostHog
  module Rails
    # PostHog can't carry part of this mail, so nothing was sent. Raised before any request, and only when the mailer's
    # `raise_delivery_errors` is on.
    class UnsupportedMailError < StandardError
      # @return [String] Which part PostHog can't carry, such as `multiple_to`, `unsupported_header` or
      #   `template_unsupported`.
      attr_reader :refusal

      # @api private
      def initialize(refusal:, detail:)
        super("PostHog cannot send this email: #{refusal}. #{detail}.")
        @refusal = refusal
      end
    end

    # PostHog did not queue the mail, or the delivery method could not tell whether it did. The PostHog::EmailError
    # behind it is its {#cause}.
    class DeliveryError < StandardError
      # @return [Integer, nil] The HTTP status, when PostHog answered.
      attr_reader :status
      # @return [String] PostHog's error code, such as `quota_limited`, or an SDK code such as `network_error`.
      attr_reader :code
      # @return [String, nil] The request field the error is about, when PostHog named one.
      attr_reader :attr
      # @return [Float, nil] How long PostHog asked to wait before sending again, in seconds.
      attr_reader :retry_after

      # @api private
      def initialize(error)
        super(error.message)
        @status = error.status_code
        @code = error.code
        @attr = error.field
        @retry_after = error.retry_after
      end

      # @return [String] Why PostHog did not queue the mail.
      def detail
        message
      end

      # Whether a later delivery of the same mail can succeed. Retry with the same X-PostHog-Idempotency-Key: PostHog
      # may have queued the first attempt, and a retry with a new key could send the mail twice.
      #
      # @return [Boolean]
      def retryable?
        case status
        when nil then code == 'network_error'
        when 409 then code == 'idempotency_key_in_flight'
        when 429 then code != 'quota_limited'
        else status == 503
        end
      end
    end
  end
end
