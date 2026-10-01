---
'posthog-ruby': patch
---

MCP analytics: sanitize only the part of a long string that truncation keeps, so capturing a large tool response (an HTML email, a big document) no longer scans every byte on the tool-call thread. The captured event is unchanged.
