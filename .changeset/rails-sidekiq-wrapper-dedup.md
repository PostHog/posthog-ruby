---
'posthog-rails': patch
---

Unwrap Sidekiq retry control-flow errors reported through Rails before filtering and capture, preventing duplicate events for job errors already captured by Active Job and reporting the original exception when it has not been captured.
