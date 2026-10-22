---
'posthog-rails': patch
---

Update the core SDK dependency so Rails events with numeric NaN or infinities serialize as JSON null instead of being lost.
