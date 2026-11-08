---
'posthog-rails': patch
---

Report Sidekiq retry failures using the original exception, preventing duplicate Active Job error events while honoring exclusions for both the wrapper and the original error.
