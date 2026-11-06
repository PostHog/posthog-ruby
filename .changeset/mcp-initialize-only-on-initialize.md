---
"posthog-ruby": patch
---

`PostHog::MCP` now sends `$mcp_initialize` only for a client's `initialize` request. A session's first `tools/call`, listing or resource read without an `initialize` (stateless HTTP or a lone call) no longer emits one, so fewer `$mcp_initialize` events will arrive.
