---
"posthog-ruby": patch
---

`PostHog::MCP` capture no longer slows down on large agent input. The intent card check is linear in the length of a digit run; a long `context` argument made it quadratic. The intent is scanned only as far as truncation keeps it. Tool parameters are cut to the depth and breadth limits before sanitizing, and a sensitive key is redacted without reading what it holds. What counts as a card, SSN or phone number is unchanged.
