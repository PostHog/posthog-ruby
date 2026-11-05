---
"posthog-ruby": minor
---

`client.emails.send` takes `integration:`, for a library that sends email on the app's behalf, such as a mailer adapter. Pass its name and version, such as `integration: 'action-mailer/3.14.0'`, and the send carries it as the `X-PostHog-Integration` header, so PostHog can tell which integration sent the email. A value outside `name/version` raises `ArgumentError` before any request. The User-Agent doesn't change.
