# frozen_string_literal: true

require 'posthog/unresolved_flag_reason'

module PostHog
  # InconclusiveMatchError is raised when local evaluation cannot determine a flag's
  # value. {#reason} says why, as reported by {FeatureFlagEvaluations#unresolved_flags}.
  class InconclusiveMatchError < StandardError
    # @return [String] One of the {UnresolvedFlagReason} values.
    attr_reader :reason

    # @param message [String, nil]
    # @param reason [String] One of the {UnresolvedFlagReason} values.
    def initialize(message = nil, reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      super(message)
      @reason = reason
    end
  end

  # RequiresServerEvaluation is raised when feature flag evaluation requires
  # server-side data that is not available locally (e.g., static cohorts,
  # experience continuity). This error should propagate immediately to trigger
  # API fallback, unlike InconclusiveMatchError which allows trying other conditions.
  class RequiresServerEvaluation < StandardError
    # @return [String] One of the {UnresolvedFlagReason} values.
    attr_reader :reason

    # @param message [String, nil]
    # @param reason [String] One of the {UnresolvedFlagReason} values.
    def initialize(message = nil, reason: UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      super(message)
      @reason = reason
    end
  end
end
