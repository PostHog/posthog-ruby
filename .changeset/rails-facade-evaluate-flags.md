---
"posthog-rails": patch
---

`PostHog.evaluate_flags` is now defined on the Rails facade next to the other flag methods, instead of reaching the client only through `method_missing`. Use it in place of the deprecated `PostHog.is_feature_enabled` and `PostHog.get_feature_flag`.
