---
"posthog-rails": minor
---

Excluded exceptions now also match subclasses of a listed class and any exception whose cause chain contains one, for both `excluded_exceptions` and the built-in defaults. For example an error raised while rescuing `ActiveRecord::RecordNotFound` is no longer captured. ActiveJob captures now respect the exclusion list too.
