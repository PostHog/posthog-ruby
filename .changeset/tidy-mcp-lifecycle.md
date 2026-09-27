---
"posthog-ruby": patch
---

Fix instance tracking for client subclasses so `PostHog::MCP::Client` can initialize outside test mode and shut down without raising.
