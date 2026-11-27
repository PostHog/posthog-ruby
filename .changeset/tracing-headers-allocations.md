---
"posthog-rails": patch
---

Allocate fewer objects on requests without PostHog tracing headers, by skipping Rack env keys that can't match a tracing header before normalizing them.
