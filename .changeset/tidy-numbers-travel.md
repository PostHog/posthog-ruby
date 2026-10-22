---
'posthog-ruby': patch
---

Serialize numeric NaN and positive or negative Infinity in event properties as JSON null instead of losing the event. Preserve nested properties, array positions, and caller-owned values in synchronous and background delivery.
