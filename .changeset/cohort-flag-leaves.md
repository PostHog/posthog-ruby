---
"posthog-ruby": patch
---

Local flag evaluation now treats a `flag_evaluates_to` leaf inside a cohort as a non-match, as the flags service does, instead of falling back to the server. A negated leaf matches.
