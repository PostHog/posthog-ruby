---
"posthog-ruby": minor
---

`emails.send` takes a `category`: `PostHog::Emails::TRANSACTIONAL`, the same as leaving it out, or the key of one of the project's marketing message categories. A marketing email skips recipients who opted out and needs an `{{ unsubscribe_url }}` link.
