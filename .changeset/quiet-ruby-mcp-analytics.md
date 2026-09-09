---
'posthog-ruby': minor
---

Add `PostHog::MCP`, experimental MCP analytics for servers built on the official `mcp` gem. `require 'posthog/mcp'` and `PostHog::MCP.instrument(server, client)` captures `$mcp_initialize`, `$mcp_tools_list`, `$mcp_tool_call`, prompt/resource events, `$mcp_missing_capability`, `$identify` and sibling `$exception` events with the same wire contract as `@posthog/mcp` and `posthog.mcp` (agent intent via an injected `context` argument, conversation ids, stateless `Mcp-Session-Id` tokens, sanitization and truncation). Also adds `PostHog::MCP::Client` for custom dispatchers, `PostHog::MCP::RackMiddleware`, and a private per-event `_lib`/`_lib_version` override in `Client#capture` so MCP events report `$lib: posthog-ruby-mcp` without relabeling the host client. The API and event schema may change in a minor release while experimental.
