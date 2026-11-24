---
"posthog-ruby": minor
---

Add `person_property_keys_known_absent:` and `group_property_keys_known_absent:` to flag evaluation methods and `SendFeatureFlagsOptions`. A listed key is treated as absent during local evaluation, even when a value for it is passed, so `is_not_set` and the negated operators match and other operators don't, without a remote request. Fallback `/flags` requests carry the same keys. Each list allows at most 1000 keys, per group type for groups. A longer list raises `ArgumentError`, except on `capture(send_feature_flags:)`, which logs a warning and captures the event without flags.
