---
"posthog-rails": minor
---

Add opt-in structured logs for controller, SQL, Active Job, and Action Mailer notifications through the existing logs pipeline. Notification records use allowlisted metadata, filtered parameter payloads, and the same severity threshold, scrubbing hook, rate cap, and context correlation as forwarded logs. Parameter filtering preserves native Rails custom-filter key/value semantics and redacts unsafe or oversized trees instead of exporting partial data.
