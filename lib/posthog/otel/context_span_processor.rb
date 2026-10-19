# frozen_string_literal: true

require 'posthog/internal/context'

module PostHog
  class ContextSpanProcessor
    def on_start(span, _parent_context)
      Internal::SpanContext.apply(span)
    end

    def on_finish(_span); end

    def force_flush(**_options)
      0
    end

    def shutdown(**_options)
      0
    end
  end
end
