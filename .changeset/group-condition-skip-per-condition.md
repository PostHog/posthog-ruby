---
"posthog-ruby": patch
---

Local flag evaluation now skips a group condition without a usable group key one condition at a time, as the server does. A group flag with a person condition (`aggregation_group_type_index: null`) is no longer `false` without the group key: the person condition still decides, also when the flag is a dependency. A group flag with a holdout that excludes anyone and no usable group key is now unresolved with `missing_context` and falls back to `/flags`.
