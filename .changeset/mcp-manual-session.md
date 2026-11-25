---
"posthog-ruby": minor
---

Every event `PostHog::MCP::Client` sends now carries a `$session_id`: the `session_id` you pass, or else a fresh one of its own, which also becomes the anonymous `distinct_id` in place of `"anonymous"`. `capture_tool_call` takes `request_meta:` and `client_name:`, and groups a call by a recognized client's conversation id, such as ChatGPT's `openai/session`. `capture_missing_capability` no longer sends the `parameters:` it is given as `$mcp_parameters`.
