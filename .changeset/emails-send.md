---
"posthog-ruby": minor
---

Send transactional email with `client.emails.send`, from an email template made in PostHog (`template_id:` with `template_data:`) or from content your code rendered (`template_key:`, `subject:` and `html:` or `text:`). Read what happened to a sent email with `client.emails.get(message_id)`. Sends need `secret_key`, a project secret API key with the `transactional_email:write` scope (status reads also accept `transactional_email:read`), and go to the PostHog Cloud app host of the client's `host`; set `app_host` for any other host. A send retries network errors, rate limits and an unavailable service with the same idempotency key, and raises `PostHog::EmailError` when PostHog doesn't queue the email. To send a React email, render it to HTML in your app first. New client options: `app_host`, `email_request_timeout_seconds`, `email_request_max_retries` and `migrated_from`.
