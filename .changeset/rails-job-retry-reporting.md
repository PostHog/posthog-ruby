---
"posthog-rails": minor
---

Add opt-in `report_active_job_retries` reporting for Active Job retry failures, reusing job identity, filtered arguments, and core exception deduplication. The option defaults to false and requires `auto_instrument_active_job`. Retry reports support Rails 5.2 and honor exception exclusions across the serialized cause chain without changing terminal reporting.
