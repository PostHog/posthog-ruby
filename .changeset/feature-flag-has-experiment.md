---
"posthog-ruby": minor
---

feat: add a `$feature_flag_has_experiment` boolean property to `$feature_flag_called` events when the server explicitly reports the `has_experiment` field; the property is omitted when the server does not report it (older deployments)
