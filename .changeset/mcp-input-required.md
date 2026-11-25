---
"posthog-ruby": minor
---

`PostHog::MCP` records an `input_required` round as `$mcp_input_required` instead of a `$mcp_tool_call`, and adds `PostHog::MCP::Client#capture_input_required` with `PostHog::MCP.input_request_methods` for custom dispatchers.
