---
"posthog-rails": minor
---

Capture terminating Rails runner exceptions before SDK shutdown when automatic exception capture is enabled. Preserve exit status and error output, report deliberate nonzero exits as fatal runner failures, skip successful exits and signal termination, and respect exception exclusions and existing capture hooks without creating an uninitialized client. Retain the original Rails-reported error for inline conversions and preserve reporter identity and serialized context.
