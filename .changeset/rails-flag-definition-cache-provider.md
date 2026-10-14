---
"posthog-rails": minor
---

Add `config.flag_definition_cache_provider` to the `PostHog.init` block so Rails apps can share feature flag definitions across processes via an external cache (for example Redis). The generated initializer now documents the option.
