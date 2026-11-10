---
"posthog-ruby": minor
---

A send with your own content now takes `tracking:` to choose what PostHog tracks for the email. Left out, PostHog counts opens and captures engagement events, and doesn't track clicks. `true` turns on opens, clicks and engagement events, and `false` turns them all off. A Hash such as `{ clicks: true }` sets `:opens`, `:clicks` and `:engagement` one by one. `capture_engagement:` is deprecated in favor of `tracking: { engagement: false }`; it still works, but a send can't set both. The client now sends it only when you set it; PostHog already reads a missing value as on. The field needs PostHog's API support, which is rolling out: until then, PostHog refuses a send that sets it.
