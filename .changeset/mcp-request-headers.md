---
"posthog-ruby": minor
---

MCP: `identify`, `intent_fallback` and `event_properties` callbacks now receive every HTTP request header in `extra['headers']` (lowercase names, a copy per callback), so a callback can resolve a user from an `Authorization` bearer token or an API key. The SDK never captures header values. Resolve a header to an id instead of returning its raw value in identity properties or `event_properties`, which are sent unredacted.
