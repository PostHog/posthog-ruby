---
"posthog-ruby": patch
---

Defer incompatible local feature flag regex patterns to server evaluation instead of returning incorrect results, including Unicode shorthand classes, line anchors, and unsupported syntax.
