---
'posthog-ruby': patch
---

Reject semver values with leading zeros (e.g. `1.07.3`, `01.02.03`) during local feature flag evaluation, per semver 2.0.0 §2. Both override values and flag values are validated; invalid inputs raise `InconclusiveMatchError` so the condition does not match.
