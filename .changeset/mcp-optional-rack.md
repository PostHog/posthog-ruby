---
'posthog-ruby': patch
---

Fix `PostHog::MCP.instrument` raising `LoadError` at boot on stdio-only MCP servers that don't have the `rack` gem installed. A missing `rack` now only skips the Streamable HTTP transport extension.
