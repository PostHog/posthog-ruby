---
"posthog-rails": patch
---

fix: stop capturing a second, context-free $exception for every unhandled web request exception. ActionDispatch::Executor reports to Rails.error after the response has unwound past CaptureExceptions, so ErrorSubscriber no longer saw it as a web request and re-captured it without $current_url, $request_path or $user_agent
