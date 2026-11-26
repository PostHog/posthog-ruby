---
"posthog-ruby": patch
---

In `sync_mode`, `flush(timeout:)` and `shutdown(timeout:)` now honor the timeout. If a request is still in flight when it elapses, they return `false` instead of waiting for the request and its retries to finish. `shutdown` then closes the connection once that request completes. A timed call from an `on_error` callback returns `false` right away instead of raising `ThreadError`. Calls without a timeout behave as before.
