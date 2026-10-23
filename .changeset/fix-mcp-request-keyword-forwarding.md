---
"posthog-ruby": patch
---

Fix MCP instrumentation returning internal errors with mcp 1.8.0 by forwarding request keywords, including authentication context, to the MCP server.
