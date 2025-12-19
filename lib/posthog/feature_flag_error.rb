# frozen_string_literal: true

module PostHog
  # Error type constants for the $feature_flag_error property.
  #
  # These values are sent in analytics events to track flag evaluation failures.
  # They should not be changed without considering impact on existing dashboards
  # and queries that filter on these values.
  #
  # Error values:
  #   ERRORS_WHILE_COMPUTING: Server returned errorsWhileComputingFlags=true
  #   FLAG_MISSING: Requested flag not in API response
  #   QUOTA_LIMITED: Rate/quota limit exceeded
  #   TIMEOUT: Request timed out
  #   CONNECTION_ERROR: Network connectivity issue
  #   UNKNOWN_ERROR: Unexpected exceptions
  #
  # For API errors with status codes, use the api_error() method which returns
  # a string like "api_error_500".
  class FeatureFlagError
    ERRORS_WHILE_COMPUTING = 'errors_while_computing_flags'
    FLAG_MISSING = 'flag_missing'
    QUOTA_LIMITED = 'quota_limited'
    TIMEOUT = 'timeout'
    CONNECTION_ERROR = 'connection_error'
    UNKNOWN_ERROR = 'unknown_error'

    # Generate API error string with status code.
    #
    # @param status [Integer, String] The HTTP status code
    # @return [String] Error string in format "api_error_STATUS"
    def self.api_error(status)
      "api_error_#{status.to_s.downcase}"
    end
  end
end
