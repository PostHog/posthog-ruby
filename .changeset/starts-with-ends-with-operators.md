---
"posthog-ruby": minor
---

Support the `starts_with`, `not_starts_with`, `ends_with`, and `not_ends_with` property filter operators in feature flag local evaluation. Matching is case-insensitive and mirrors `icontains`, so flags using these operators no longer fall back to remote evaluation.

Case folding for `icontains`, `not_icontains`, and the four new operators is now ASCII-only (`downcase(:ascii)`), matching the flags service. This is observable for non-ASCII values: `Ä` and `ä` no longer match case-insensitively, which aligns local results with remote evaluation.
