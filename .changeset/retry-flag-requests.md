---
"posthog-ruby": patch
"posthog-rails": patch
---

Retry feature flag requests on transient network errors (timeouts, connection resets) with backoff, so a one-off blip no longer surfaces a hard error to the caller. The retry count is configurable via the `feature_flag_request_max_retries` option (defaults to 1, set to 0 to opt out).
