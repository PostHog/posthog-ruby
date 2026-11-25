---
"posthog-ruby": patch
---

Local evaluation now evaluates a flag dependency like a standalone flag, with its own aggregation, properties and bucketing identifier. A group-aggregated dependency reads its group's properties and is `false` when that group isn't passed, matching `/flags`.
