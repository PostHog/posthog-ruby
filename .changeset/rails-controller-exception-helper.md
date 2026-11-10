---
"posthog-rails": minor
---

Add a private controller capture_exception helper with filtered request metadata, configured user identity, explicit argument precedence, and the existing exception capture pipeline. Manual reports work independently of automatic exception capture without initializing an unavailable client.
