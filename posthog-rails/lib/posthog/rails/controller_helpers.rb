# frozen_string_literal: true

require 'posthog/rails/exception_context'

module PostHog
  module Rails
    module ControllerHelpers
      private

      # Report a handled exception with filtered Rails request context.
      # Manual reporting is independent of automatic capture and its exclusions.
      #
      # @param exception [Exception, String, Object] Input accepted by {PostHog::Client#capture_exception}.
      # @param distinct_id [String, nil] Explicit identity, before configured user and request identity.
      # @param additional_properties [Hash, nil] Explicit properties override inferred request properties.
      # @param flags [PostHog::FeatureFlagEvaluations, nil] Flag evaluation snapshot.
      # @param mechanism [Hash, nil] Explicit exception mechanism; defaults to core manual capture semantics.
      # @return [Boolean, nil] The result of {PostHog.capture_exception}, or false when unavailable or capture fails.
      def capture_exception(exception, distinct_id = nil, additional_properties = {}, flags: nil, mechanism: nil)
        return false unless PostHog.initialized? && PostHog.client.enabled?

        context = ExceptionContext.new(request, self, manual: true)
        distinct_id = context.distinct_id if distinct_id.nil?
        properties = context.properties.merge(additional_properties || {})

        PostHog.capture_exception(exception, distinct_id, properties, flags: flags, mechanism: mechanism)
      rescue StandardError
        PostHog::Logging.logger.error('Failed to capture controller exception')
        false
      end
    end
  end
end
