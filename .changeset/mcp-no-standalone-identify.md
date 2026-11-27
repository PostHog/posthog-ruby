---
"posthog-ruby": minor
---

`PostHog::MCP` no longer sends a standalone `$identify` event. Every event already carries the identity your `identify` option resolves, as its `distinct_id`, `$set`, and `$groups`, and `$exception` now carries `$set` too.
