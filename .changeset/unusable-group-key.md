---
"posthog-ruby": patch
---

Treat an empty, `nil`, boolean, array, or hash group key as no group key during local flag evaluation, as the server does. A condition aggregated on that group type is skipped, and a flag whose conditions are all skipped resolves to `false` locally instead of bucketing on the key's string form.
