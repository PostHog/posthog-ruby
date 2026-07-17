---
"posthog-ruby": minor
---

Add a `feature_flags_async_load` client option that keeps feature flag definition fetches off the calling thread. With it enabled the constructor no longer blocks on the initial `/flags/definitions` request; the poller fetches immediately on boot (the timer's first tick) and, if that fails (e.g. PostHog unreachable), keeps retrying on its regular polling interval instead of re-fetching inline on evaluation calls. Until the first load succeeds, local evaluation treats definitions as absent. Also adds `Client#feature_flags_loaded?` so callers can distinguish "flag is off or unknown" from "definitions not loaded yet". Defaults to off; the existing synchronous behavior is unchanged.
