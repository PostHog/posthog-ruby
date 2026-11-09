---
'posthog-rails': minor
---

Add an explicitly loaded Sidekiq integration with reporting policies for every failed attempt, terminal failure notifications, or dead-queue failures. The integration owns automatic job error reporting to prevent duplicate Rails and Active Job events. Requires Rails 7.1+ and Sidekiq 7.0.3+; older versions warn and keep existing reporting.
