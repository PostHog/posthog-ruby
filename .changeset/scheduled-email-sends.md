---
"posthog-ruby": minor
---

Schedule a transactional email with `scheduled_at` on `emails.send`, at most 7 days ahead, on PostHog Cloud. The result's `status` is `scheduled` with the confirmed `scheduled_at`, or `queued` when the time had passed. `emails.get` reads `scheduled` until the email goes out. The client rounds a finer time up to the next millisecond and refuses a time without an offset. It refuses to schedule on any host other than PostHog Cloud US or EU, and raises `schedule_not_confirmed` with `EmailError#message_id` when PostHog accepts the email without confirming its time, also when PostHog would send now an email due more than a minute ahead. `SendResult` gains a `scheduled_at` member, so a `SendResult` marshaled by an earlier version, such as one in a Rails cache, doesn't load in this version, and one marshaled by this version doesn't load in an earlier one.
