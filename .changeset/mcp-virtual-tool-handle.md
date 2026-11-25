---
"posthog-ruby": minor
---

`PostHog::MCP`'s `get_more_tools` virtual tool now follows the conversation handle like any tool: it advertises `conversation_id`, files a report under a handle the agent echoes, and mints and returns one when nothing else groups the call. `$mcp_missing_capability` no longer carries `$mcp_parameters`; the report is already its `$mcp_intent`.
