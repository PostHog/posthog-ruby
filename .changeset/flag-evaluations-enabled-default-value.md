---
'posthog-ruby': minor
---

Add an optional `default_value:` keyword to `PostHog::FeatureFlagEvaluations#enabled?`. It is returned when the flag has no value in the snapshot — it was never loaded, the `/flags` request failed, or no flag with that key exists — while a flag that does have a value, including `false` and variant strings, still wins over the default. A flag the server returned but marked as failed resolves to `false`, not the default. Calls that omit the keyword keep returning `false` for a missing flag.
