---
'posthog-ruby': minor
---

Add `PostHog::MCP`, **experimental and unsupported** MCP analytics for servers built on the official `mcp` gem. This is not an officially supported PostHog SDK: no support is provided for it, and its API, its options, and the `$mcp_*` event schema it captures may change in a minor release. A warning is logged when you `require 'posthog/mcp'`. Docs: https://posthog.com/docs/mcp-analytics

`PostHog::MCP.instrument(server, client)` captures `$mcp_initialize`, `$mcp_tools_list`, `$mcp_tool_call`, prompt/resource events, `$mcp_missing_capability`, `$identify` and sibling `$exception` events (agent intent via an injected `context` argument, conversation ids, stateless `Mcp-Session-Id` tokens, sanitization and truncation). Also adds `PostHog::MCP::Client` for custom dispatchers, `PostHog::MCP::RackMiddleware`, and a private per-event `_lib`/`_lib_version` override in `Client#capture` so MCP events report `$lib: posthog-ruby-mcp` without relabeling the host client.
