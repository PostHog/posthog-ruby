---
'posthog-ruby': patch
---

Creating a `PostHog::Client` when Rails is loaded but the app hasn't booted yet (so `Rails.logger` is `nil`) no longer raises `NoMethodError`. The default logger now looks up `Rails.logger` on every log call: it writes to `$stderr` while `Rails.logger` is `nil` and switches to `Rails.logger` once the app sets it.
