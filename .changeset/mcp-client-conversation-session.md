---
"posthog-ruby": minor
---

`PostHog::MCP` groups ChatGPT, Codex, and VS Code calls by the conversation id each client sends in `_meta`, and every event now carries `$mcp_session_source`. ChatGPT is no longer advertised or minted a `conversation_id`. On stateless HTTP, a request that carries no session gets a `$session_id` of its own instead of the server's, and is no longer named after another client's handshake. A custom event captured during a tool call carries the session and identity that call records, including a conversation handle the call delivers.
