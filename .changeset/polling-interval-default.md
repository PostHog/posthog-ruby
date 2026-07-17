---
"posthog-ruby": patch
---

fix: honor the documented 30s default for `feature_flags_polling_interval`. The resolved default was computed but never passed to the polling timer, so when the option was unset the effective interval was concurrent-ruby's 60s TimerTask default. Definitions now poll every 30s by default as documented; set `feature_flags_polling_interval: 60` to keep the previous effective cadence.
