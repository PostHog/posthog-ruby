---
"posthog-ruby": minor
---

`emails.send` takes a `category` on sends with `template_key`: `PostHog::Emails::TRANSACTIONAL`, the same as leaving it out, or a `PostHog::Emails::MessageCategory` with a `key`, `type` (`marketing` or `transactional`), `name` and optional `description`. PostHog creates the category the first time a send names its key. A marketing email skips recipients who opted out and needs an `{{ unsubscribe_url }}` link.
