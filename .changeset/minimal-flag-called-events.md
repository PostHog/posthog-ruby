---
"posthog-ruby": minor
---

feat: emit minimal `$feature_flag_called` events when the server enables the `minimal_flag_called_events` gate and the evaluated flag has no linked experiment. Minimal events keep a strict allowlist of flag-evaluation properties and strip everything else (context properties, `$feature/<key>`, payloads, system metadata). The gate is read from the top-level `minimalFlagCalledEvents` field of the v2 `/flags` response and the top-level `minimal_flag_called_events` key of the local evaluation definitions payload; when either signal is missing, the full event is sent unchanged.
