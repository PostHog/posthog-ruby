---
'posthog-ruby': patch
---

`PostHog::Client.new` no longer raises `NoMethodError` when `Rails` is defined but has no usable logger: before the app boots (`Rails.logger` is `nil`), or when a gem such as `rails-html-sanitizer` defines `Rails` without railties. The default logger now looks up `Rails.logger` on every log call. It writes to `$stderr` until `Rails.logger` is set, then switches to it.
