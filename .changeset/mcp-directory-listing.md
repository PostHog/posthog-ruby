---
"posthog-ruby": minor
---

`PostHog::MCP` tool definitions now match what directory reviews expect. The `get_more_tools` virtual tool declares `readOnlyHint`, `destructiveHint`, `idempotentHint` and `openWorldHint` as `false`, because a call records data. The injected `context` argument has a shorter description that asks for a few words by role. The injected `llm_model` argument is optional. This changes your published tool definitions; if your server is listed in the ChatGPT or Claude directories, those platforms may re-review the updated tools.
