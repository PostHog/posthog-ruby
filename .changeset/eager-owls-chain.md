---
"posthog-ruby": minor
"posthog-rails": minor
---

Improve error tracking capture signals:

- `capture_exception` now walks the full `exception.cause` chain (outermost-first, cycle-safe, capped at 50) instead of reporting only the outermost exception; chained causes are tagged with a `chained` mechanism and parent linkage.
- Exception mechanisms now reflect the capture source: manual captures stay `generic`/`handled: true`, while the Rails middleware, `Rails.error` subscriber, and ActiveJob integrations tag captures as `rails`/`rails_error_reporter`/`active_job` with the correct `handled` flag. `capture_exception` accepts a `mechanism:` keyword.
- Stack frame `filename` values are now project-relative paths (relative to the Rails root or `Dir.pwd`, falling back to the basename outside the project) so fingerprints stay stable across per-host deploy directories; `abs_path` keeps the raw absolute path. `in_app` is now based on gem/stdlib install locations (`Gem.path`, loaded gem specs, `rubylibprefix`) instead of path substrings.
