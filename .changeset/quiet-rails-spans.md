---
"posthog-ruby": minor
"posthog-rails": patch
---

Add an optional context span processor for application OpenTelemetry spans. Rails request context adds session and person IDs to the active recording request span and preserves explicit span attributes.
