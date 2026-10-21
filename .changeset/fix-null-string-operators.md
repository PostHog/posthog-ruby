---
"posthog-ruby": patch
---

Fix local feature flag evaluation to stringify explicitly null properties as "null" instead of an empty string for contains, prefix, suffix, and regex operators (including their negations). Flag values or selected variants can change for explicitly null person or group properties; missing properties still allow remote evaluation fallback.
