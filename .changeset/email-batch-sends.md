---
"posthog-ruby": minor
---

Send the same transactional email to many recipients with `emails.batch`, one email each, from a template made in PostHog with `template_data` per recipient, or from content your code rendered. The client sends at most 100 recipients and 4 MiB per request, one request after another, and returns a result per recipient in order: `queued`, `failed`, `unconfirmed` or `not_attempted`. Each recipient has its own `idempotency_key`, given or made by the client, so a retry or a rerun within 24 hours never sends an email twice. A request that fails as a whole stops the batch and raises `EmailBatchError` with every recipient's result.
