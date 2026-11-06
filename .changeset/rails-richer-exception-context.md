---
"posthog-rails": minor
---

Add opt-in filtered request header, cookie and structured body context for Rails exceptions, automatic filtered ExecutionContext snapshots, and GlobalID-aware bounded metadata serialization. Preserve input positions and avoid parsing unsafe or malformed uncached bodies through Rails diagnostics. Preserve custom Rails filter key/value semantics before JSON normalization and omit unsafe metadata rather than partially filtering truncated data.
