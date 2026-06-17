---
"posthog-ruby": patch
---

Fix Rails initializer load order so `PostHog.init` is available when `posthog-rails` is required.
