---
"posthog-ruby": patch
---

On stdio, `PostHog::MCP` rolls the connection's `$session_id` over for the first tool call that arrives 30 minutes or more after the previous tool call ended. Listings no longer keep the session alive, and every event of a call keeps the session the call arrived with, however long it runs. A custom event captured before the first request now carries the connection's session.
