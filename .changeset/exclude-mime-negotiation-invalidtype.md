---
'posthog-ruby': patch
---

posthog-rails: exclude `ActionDispatch::Http::MimeNegotiation::InvalidType` from captured exceptions by default. It is raised on malformed `Accept`/`Content-Type` headers (almost always scanner traffic) and mapped to a 406 by Rails, so it is noise rather than an app error.
