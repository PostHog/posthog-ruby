---
"posthog-ruby": patch
"posthog-rails": patch
---

Remove unstable numeric suffixes from Rails-generated template method names in exception frames when the name matches the template source path. Preserve filenames, line numbers, source context, frame classification, cause chains, and duplicate capture prevention.
