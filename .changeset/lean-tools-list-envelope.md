---
'posthog-ruby': patch
---

Stop copying the tool descriptors into `$mcp_response` on `$mcp_tools_list` events. The response keeps only the envelope (`nextCursor`, `ttlMs`, and so on) and the tool names stay in `$mcp_listed_tool_names`.
