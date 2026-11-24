---
"posthog-ruby": minor
---

Require Ruby 3.2 or later. Ruby 3.0 and 3.1 are end-of-life and CI hasn't tested them. The changelog for 3.0.0 already listed Ruby 3.2 as the minimum, but the gemspec still allowed 3.0. Apps on Ruby 3.0 or 3.1 will keep resolving to the last posthog-ruby release that allowed them.
