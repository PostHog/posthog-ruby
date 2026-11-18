---
"posthog-ruby": patch
---

Send transactional emails, attachment uploads, and email status requests through `/api/messaging/` instead of the `/api/projects/@current/messaging/` alias. Needs PostHog Cloud, or a self-hosted PostHog from 2026-11-18 or later. Older self-hosted versions answer these calls with a 404.
