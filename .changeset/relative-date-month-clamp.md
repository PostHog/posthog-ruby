---
"posthog-ruby": patch
---

Relative date filters in local flag evaluation now clamp the day after every month or year step, as the SDK spec requires. `2m` on March 31 resolves to January 28 instead of January 31, and `4y` on February 29, 2024 to February 28, 2020.
