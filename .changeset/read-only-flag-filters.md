---
'posthog-ruby': patch
---

Prevent concurrent local feature flag lookups from failing with hash iteration errors, and avoid modifying the groups and properties supplied to flag evaluation.
