---
'posthog-ruby': minor
---

Read the release id from the `POSTHOG_RELEASE_ID` environment variable and send it as `$release_id` on every event, including `$exception`, `$identify`, `$groupidentify`, `$create_alias` and minimal `$feature_flag_called` events. On `$exception` events, error tracking uses it to link the exception to its release by a direct id lookup. Create the release and get its id with `posthog-cli release resolve`. The client reads the variable once, when it is created. An explicit `$release_id` in the event properties or the request context wins over the environment variable, and `before_send` can still change or remove it.
