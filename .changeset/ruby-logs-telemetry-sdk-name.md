---
"posthog-rails": patch
---

Stamp `telemetry.sdk.name = "posthog-ruby"` on forwarded logs so PostHog can attribute log volume to the Ruby SDK. Previously these records carried the OpenTelemetry SDK default (`opentelemetry`), so they could not be split out per-SDK the way the mobile SDKs are.
