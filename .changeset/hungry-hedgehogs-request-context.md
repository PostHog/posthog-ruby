---
"posthog-ruby": minor
---

Add internal request context support for Rails so request metadata is applied to captures and exception events during a request, with optional PostHog tracing header support for request-scoped identity/session context. Captures without an explicit distinct_id now use request context when available, otherwise they are sent as personless events with a generated UUID.
