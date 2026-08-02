---
"posthog-ruby": minor
---

feat: add optional `timeout:` argument to `Client#shutdown` and `Client#flush`, bounding how long they block waiting for the async queue to drain. Both methods now return a Boolean: `true` if everything pending was sent, `false` if the timeout elapsed first (for `shutdown`, events still queued at expiry are not sent). Omitting the argument preserves the previous wait-indefinitely behavior. In sync mode the argument is accepted and ignored, returning `true`.
