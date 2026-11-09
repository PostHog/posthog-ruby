---
"posthog-rails": patch
---

Stop automatically collecting request parameters and referrers on Rails exceptions to reduce sensitive-data exposure and align request collection with the Python and Node framework integrations. Exception capture no longer reads or parses request bodies. Basic request metadata and identity context are unchanged; applications can explicitly supply additional properties through `PostHog.capture_exception`.
