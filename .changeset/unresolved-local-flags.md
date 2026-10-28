---
"posthog-ruby": minor
---

Report flags that local evaluation could not resolve on `evaluate_flags` snapshots. `FeatureFlagEvaluations#unresolved_flags` maps each such flag key to a `PostHog::UnresolvedFlagReason` value (`experience_continuity`, `unsupported_definition`, `unresolved_dependency` or `missing_context`). `InconclusiveMatchError` and `RequiresServerEvaluation` have a new `reason` with the same values. When flag definitions load, log one warning for each flag that local evaluation can never resolve (experience continuity, a static cohort, an unknown operator, a malformed value, a regex that only the server can evaluate, or a missing or circular flag dependency), and log it again only when the definition of that flag changes.

Behavior changes (these apply to every flag method, including `get_feature_flag`, `is_feature_enabled` and `get_all_flags`, not only to `evaluate_flags`):

- A condition or a cohort property group no longer stops at the first filter that local evaluation can't check, unless that filter is a static cohort inside a cohort. If another filter does not match, the flag can now resolve locally. Before, such a flag fell back to a remote request, or stayed unresolved with `only_evaluate_locally: true`.
- An inactive flag with experience continuity enabled now resolves to `false` locally instead of falling back to a remote request.
- A flag that depends on a flag with experience continuity enabled is no longer evaluated locally. It falls back to a remote request, or stays unresolved with `only_evaluate_locally: true`.
- A flag that depends on a flag that needs the server, for example one with a static cohort, no longer forces a remote request at that condition. A later condition can now resolve the flag locally.
- `$feature_flag_called` events from snapshot reads report `local_evaluation_inconclusive` instead of `flag_missing` for flags in `unresolved_flags`.
- When local evaluation left a flag unresolved and the remote fallback marks it as failed, the snapshot no longer holds it as `false`. The flag is absent from the snapshot and listed in `unresolved_flags`, so `enabled?` returns the `default_value:` you pass (this reverses the 3.27.0 rule for these flags) and `get_flag` returns `nil`. A failed flag that has no local definition keeps its `false` value and still ignores `default_value:`.
- The load-time warning is logged at WARN level, so it shows without debug logging.
