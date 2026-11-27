---
"posthog-ruby": patch
---

Feature flag payloads that aren't valid JSON now read as no payload instead of being returned as a raw string. `evaluate_flags(...).get_flag_payload`, `get_feature_flag_result(...).payload` and the deprecated `get_feature_flag_payload` return `nil` and log a warning when a flag's stored payload can't be parsed, including empty and whitespace-only payloads. The flag's value and other flags' payloads are unaffected.
