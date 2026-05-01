---
"posthog-ruby": minor
---

Add `evaluate_flags(distinct_id, …)` returning a `FeatureFlagEvaluations` snapshot, and a `flags:` option on `capture` so a single `/flags` call can power both flag branching and event enrichment per request.

```ruby
snapshot = posthog.evaluate_flags("user-1", flag_keys: ["checkout-redesign"])
posthog.capture(distinct_id: "user-1", event: "checkout_started", flags: snapshot) if snapshot.enabled?("checkout-redesign")
```

The snapshot exposes `enabled?`, `get_flag`, `get_flag_payload`, plus `only_accessed` / `only([keys])` filter helpers. `flag_keys:` scopes the underlying `/flags` request itself. `enabled?` and `get_flag` fire `$feature_flag_called` events with full metadata (`$feature_flag_id`, `$feature_flag_version`, `$feature_flag_reason`, `$feature_flag_request_id`), deduped through the existing per-distinct_id cache. `get_flag_payload` does not record access or fire an event.

Deprecates `is_feature_enabled`, `get_feature_flag`, `get_feature_flag_result`, `get_feature_flag_payload`, and `capture(send_feature_flags:)`. They continue to work unchanged but now emit a one-time deprecation warning per method pointing at `evaluate_flags()`. Removal is planned for the next major version.
