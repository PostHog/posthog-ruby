---
"posthog-ruby": patch
---

`PostHog::MCP::Analytics#flush` no longer raises into host code or blocks without limit. It waits up to `timeout:` seconds for the client to send its queue (10 by default), and a failed or timed-out flush is logged instead of raised.
