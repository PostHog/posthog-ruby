---
"posthog-rails": minor
---

Add opt-in structured logs for controller, SQL, Active Job, and Action Mailer notifications through the existing logs pipeline. Notification records use allowlisted metadata, filtered parameter payloads, and the same severity threshold, scrubbing hook, rate cap, and context correlation as forwarded logs. Controller records reuse Rails' already-filtered parameters without rerunning custom filters. Job argument filtering preserves native Rails custom-filter key/value semantics, honors argument logging opt-outs, and omits mail delivery job arguments. Unsafe or oversized trees are redacted instead of exporting partial data. Rescued Active Job enqueue errors are logged at error severity, and suppressed notification records skip parameter processing.
