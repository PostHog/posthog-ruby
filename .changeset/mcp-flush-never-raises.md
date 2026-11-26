---
"posthog-ruby": patch
---

`PostHog::MCP::Analytics#flush` no longer raises into host code or blocks without limit. It waits at most 10 seconds for the client to send its queue, and a failed or timed-out flush is logged instead of raised.
