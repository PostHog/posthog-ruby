---
'posthog-ruby': patch
---

Initialize disabled no-op clients instead of raising or sending requests when the API key is missing or blank.
