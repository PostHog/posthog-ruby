---
"posthog-ruby": minor
---

MCP: `identify`, `intent_fallback` and `event_properties` callbacks now receive every HTTP request header in `extra['headers']` (lowercase names), so a callback can resolve a user from an `Authorization` bearer token or an API key. Header values are never captured on events.
