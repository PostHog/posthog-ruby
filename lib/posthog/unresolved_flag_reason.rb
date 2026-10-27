# frozen_string_literal: true

module PostHog
  # Why local evaluation left a flag without a value, as reported by
  # {FeatureFlagEvaluations#unresolved_flags}.
  #
  # Reason values:
  #   EXPERIENCE_CONTINUITY: The flag has experience continuity enabled, which local evaluation never resolves
  #   UNSUPPORTED_DEFINITION: The flag uses something local evaluation does not support, such as a static
  #     cohort, an unknown operator, a malformed value, or a missing or circular flag dependency
  #   UNRESOLVED_DEPENDENCY: A flag this flag depends on has a loaded definition but was unresolved
  #   MISSING_CONTEXT: The call did not pass a property or group property the flag needs, or passed it in a
  #     form local evaluation cannot use
  module UnresolvedFlagReason
    EXPERIENCE_CONTINUITY = 'experience_continuity'
    UNSUPPORTED_DEFINITION = 'unsupported_definition'
    UNRESOLVED_DEPENDENCY = 'unresolved_dependency'
    MISSING_CONTEXT = 'missing_context'
  end
end
