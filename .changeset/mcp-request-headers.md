---
"posthog-ruby": minor
---

MCP: `identify`, `intent_fallback` and `event_properties` callbacks now receive every HTTP request header in `extra['headers']` (lowercase names, in a copy, so a callback that changes it cannot change how the SDK resolves the session), so a callback can resolve a user from an `Authorization` bearer token or an API key. The SDK doesn't capture this header bag automatically, and the existing `User-Agent` and `X-Anthropic-Client` telemetry (`$mcp_client_user_agent`, `$mcp_vendor_client`) is unchanged. Resolve a header to an id instead of returning its raw value in identity properties or `event_properties`, which are sent unredacted.
