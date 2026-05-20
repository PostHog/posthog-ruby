# frozen_string_literal: true

module PostHog
  # API response wrapper returned by the SDK transport.
  #
  # @api private
  class Response
    attr_reader :status, :error

    # @param status [Integer] HTTP status code, or -1 for SDK/transport errors.
    # @param error [String, nil] Error message returned by the API or SDK.
    def initialize(status = 200, error = nil)
      @status = status
      @error = error
    end
  end
end
