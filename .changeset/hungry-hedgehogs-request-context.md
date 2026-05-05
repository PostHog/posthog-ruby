---
"posthog-ruby": minor
---

Add internal request context support for Rails so PostHog tracing headers and request metadata can be applied to captures and exception events during a request. Captures without an explicit distinct_id now use request context when available, otherwise they are sent as personless events with a generated UUID.
