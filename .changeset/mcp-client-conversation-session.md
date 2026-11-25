---
"posthog-ruby": minor
---

`PostHog::MCP` groups ChatGPT, Codex, and VS Code calls by the conversation id each client sends in `_meta`, and every event now carries `$mcp_session_source`. The id is never sent itself, not even in `$mcp_parameters`, so the request your `identify` and `event_properties` callbacks receive no longer has that `_meta` key. ChatGPT is no longer advertised or minted a `conversation_id`, and neither is a call whose session the transport already carries. On HTTP, a request that carries no session, including every 2026-07-28 request, gets a `$session_id` of its own instead of the server's or the per-request session the `mcp` gem assigns, and is no longer named after another client's handshake. A custom event captured during a tool call carries the session and identity that call records, including a conversation handle the call delivers.
