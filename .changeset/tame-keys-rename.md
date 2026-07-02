---
"posthog-ruby": minor
"posthog-rails": minor
---

Add `secret_key` config option and deprecate `personal_api_key`.

`secret_key` is the new canonical credential for local feature flag evaluation and remote config. It accepts either a Personal API Key (`phx_...`) or a Project Secret API Key (`phs_...`). `personal_api_key` still works as a deprecated alias; when both are supplied, `secret_key` wins.
