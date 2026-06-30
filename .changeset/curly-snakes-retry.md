---
"posthog-ruby": patch
---

Retry capture delivery on transient HTTP errors such as 408, 429, and 5xx while continuing to avoid retries for non-retryable 4xx responses.
