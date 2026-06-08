---
"posthog-ruby": minor
---

Support the `early_exit` option in local feature flag evaluation. When a flag's `filters.early_exit` is `true`, evaluation stops and returns a definitive disabled result as soon as a condition group's property filters match (or it has none) but the rollout percentage excludes the user, instead of falling through to later condition groups. This mirrors the server-side evaluation engine (and posthog-node / posthog-python). Property-mismatch groups still fall through as before, and behavior is unchanged when `early_exit` is unset or `false`.
