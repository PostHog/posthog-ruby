---
"posthog-ruby": patch
"posthog-rails": patch
---

Retry feature flag requests on transient network errors (timeouts, connection resets) with backoff, so a one-off blip no longer surfaces a hard error to the caller.
