---
"posthog-ruby": minor
---

A send with your own content now takes `track_opens_and_clicks: false`, which sends that email without PostHog's open pixel, so PostHog can't count its opens. PostHog doesn't track clicks on emails sent from code, so their links are never rewritten either way. It defaults to `true`, and a send that leaves it out sends the same request as before. It is independent of `capture_engagement:`, which decides whether engagement events are captured on the recipient's person. The field needs PostHog's API support, which is rolling out: until then, PostHog refuses a send that sets it.
