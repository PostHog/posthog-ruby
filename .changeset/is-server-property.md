---
"posthog-ruby": patch
---

Add a configurable `$is_server` event property (default `true`) so PostHog can identify server-side events. Set `is_server: false` when using posthog-ruby as a client/CLI so the device OS is attributed normally.
