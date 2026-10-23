---
"posthog-rails": patch
"posthog-ruby": patch
---

Capture handled errors reported through `Rails.error` during web requests by replacing Rails-specific suppression with shared exception deduplication.

For mutable exceptions, `capture_exception` now suppresses subsequent captures of the same exception object and its captured causes, including manual calls and calls through another client. The first successful capture wins; subsequent calls return `false` without merging context. Supply the required identity and context on the first report. Failed captures remain retryable.

Remove `PostHog::Rails::IN_WEB_REQUEST_KEY` and the request-tracking and exception-marker helpers documented as private. Remove any application references to these integration internals.
