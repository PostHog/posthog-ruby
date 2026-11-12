---
"posthog-ruby": minor
---

`emails.send` takes a `category` on sends with `template_key`: `PostHog::Emails::TRANSACTIONAL` for transactional email with no category, or a `PostHog::Emails::MessageCategory` with a `key`, `type` (`marketing` or `transactional`), `name` and optional `description`. Leave it out for transactional email with no category, as before, or for the category of the template that `template_key` names. PostHog refuses `TRANSACTIONAL` on a template in a category with `category_mismatch`. PostHog creates the category the first time a send names its key, and uses its `name` and `description` only then; change them later in PostHog. A marketing email skips recipients who opted out and needs an `{{ unsubscribe_url }}` link.
