---
"posthog-ruby": patch
---

Compare numeric strings numerically for locally evaluated feature flag `gt`, `gte`, `lt`, and `lte` conditions, including when the filter is a JSON number. This corrects flag membership for values such as `"10" > 2` and `"100" < 30`. Invalid or non-finite property values no longer match via string ordering; invalid numeric conditions use the existing remote-evaluation fallback.
