---
"posthog-ruby": minor
---

Use stable project-relative stack frame `filename` values (relative to `Rails.root` or `Dir.pwd`, falling back to the basename outside the project) while preserving the raw path in `abs_path`; dependency and stdlib frames are detected from RubyGems/stdlib install roots, computed once per stacktrace, so `in_app` no longer depends on deploy-path substrings.
