---
"posthog-ruby": minor
---

Send the same transactional email to many recipients with `emails.batch`, one email each, from a template made in PostHog with `template_data` per recipient, or from content your code rendered. The client sends at most 100 recipients and 4 MiB per request, one request after another, and returns a result per recipient in order: `queued`, `failed`, `unconfirmed` or `not_attempted`. Each recipient has its own `idempotency_key`, given or made by the client, so the client's own retries never send an email twice. To rerun a batch that was cut off, pass the keys you stored: a rerun with the same keys within 24 hours replays the emails that went out. A request that fails as a whole stops the batch and raises `EmailBatchError` with every recipient's result.
