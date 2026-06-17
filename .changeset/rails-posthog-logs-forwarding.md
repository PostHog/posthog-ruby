---
"posthog-ruby": minor
---

Add opt-in PostHog Logs support to posthog-rails: set `config.logs_enabled = true` to forward `Rails.logger` output to PostHog Logs over OpenTelemetry (OTLP), automatically correlated with the request's PostHog distinct ID and session ID (and active trace/span when OpenTelemetry tracing is present). Includes a configurable severity filter (`logs_level`), a rate cap (`logs_max_records_per_minute`, default 6,000/min), and a `logs_before_send` callback for scrubbing or dropping records. Relies on the optional OpenTelemetry gems; when they are absent the feature warns once and no-ops.
