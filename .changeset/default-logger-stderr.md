---
'posthog-ruby': patch
---

The default logger (used outside Rails when `PostHog::Logging.logger` isn't set) now writes to `$stderr` instead of `$stdout`, so failed sends can't corrupt a program's stdout, such as a stdio MCP server's JSON-RPC stream. To keep logs on stdout, set `PostHog::Logging.logger = Logger.new($stdout)`.
