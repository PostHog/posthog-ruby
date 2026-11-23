---
"posthog-ruby": patch
---

`Time`, `ActiveSupport::TimeWithZone` and `DateTime` values in event, identify and group properties and in transactional email `template_data` are now sent in UTC with a `Z` suffix, for example `2026-11-23T05:00:15.123Z` instead of `2026-11-23T10:30:15.123+05:30`. The moment in time doesn't change, and PostHog filters and breakdowns behave the same, but a `before_send` hook or downstream export that compares the raw string sees a different value. `DateTime` values no longer go through ActiveSupport's `to_time`, so Rails 7.x no longer prints its `to_time_preserves_timezone` deprecation warning, and the result no longer depends on the Rails version, that setting or the server's `TZ`. `Date` values are unchanged.
