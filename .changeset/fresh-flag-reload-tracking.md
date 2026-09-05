---
"posthog-ruby": patch
---

Reset feature flag event deduplication when local flag definitions are refreshed or discarded, allowing the next flag access to emit a fresh event.
