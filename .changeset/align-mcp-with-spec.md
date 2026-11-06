---
"posthog-ruby": minor
---

A `tools/call` that names a tool the server never registered now sends `$mcp_unknown_tool` instead of a failed `$mcp_tool_call`; the client gets the same error as before. A call that echoes a conversation handle keeps it on the event.
