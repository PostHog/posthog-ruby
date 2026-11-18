---
"posthog-ruby": patch
---

Send transactional emails, attachment uploads, and email status requests through `/api/messaging/` instead of the `/api/projects/@current/messaging/` alias. PostHog instances without these routes answer 404.
