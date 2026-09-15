# PostHog MCP analytics for Ruby

> **Experimental and unsupported.** `PostHog::MCP` is not an officially supported PostHog SDK: no
> support is provided for it, and its API, options, and the captured `$mcp_*` event schema may change
> in a minor release. A one-line warning is logged when you require it. Bug reports and patches are
> welcome at https://github.com/PostHog/posthog-ruby/issues, but don't build production reporting on
> it yet.

Product analytics for [Model Context Protocol](https://modelcontextprotocol.io) servers built on the
official Ruby [`mcp`](https://rubygems.org/gems/mcp) gem. Wrap an `MCP::Server` so every tool call,
agent intent, handshake, listing, prompt, resource read, and failure is captured to PostHog.

**Documentation: https://posthog.com/docs/mcp-analytics** — setup, every option, the event and
property catalog, sessions on stateless/multi-pod servers, conversation ids, intent, identifying
users, privacy, and custom dispatchers. That's the single source of truth; this directory
deliberately keeps no second copy of it.

Install is just `gem 'posthog-ruby'`. `PostHog::MCP.instrument` needs the `mcp` gem (`>= 1.4`) at
runtime, but anyone wrapping a server already has it. `PostHog::MCP::Client` (custom dispatchers)
needs nothing beyond `posthog-ruby`.

## Ruby-specific notes

These are the few things that differ from what the docs describe for the other SDKs.

* **`$lib` is per event.** MCP events report `$lib: "posthog-ruby-mcp"` while the client you pass in
  keeps its own identity (`posthog-ruby` or `posthog-rails`) for everything else it sends, so
  instrumenting a server inside a Rails app doesn't relabel the app's other events.
* **Truncation is tighter.** Events are truncated to fit the core client's 32KB per-message limit,
  because posthog-ruby drops larger messages at batch time - truncating harder beats losing the
  event.
* **Request scope needs Ruby 3.2+ to be inherited.** A custom event captured from a thread or fiber
  a tool spawns is attributed to that request on 3.2+ (fiber storage); before 3.2 capture from the
  tool body itself, or an HTTP server falls back to a standalone session.
* **Composed schemas are left alone.** A tool whose `input_schema` is `oneOf`/`allOf`/`anyOf` or a
  `$ref` has nothing injected into it and nothing stripped from its calls.
* **stdio servers own `$stdout`.** The integration's own messages go only to the `logger:` you pass
  (default: nowhere); the experimental notice and misconfiguration warnings go to stderr. Point the
  core SDK's logger away from stdout too: `PostHog::Logging.logger = Logger.new($stderr)`.

## Layout

| File | What it does |
|---|---|
| `mcp.rb` (parent dir) | `PostHog::MCP.instrument` and the public helpers |
| `server_extension.rb` | Prepended onto `MCP::Server` and the Streamable HTTP transport |
| `instrumentation.rb` | Per-request dispatch: intent, identity, sessions, recording |
| `client.rb` | `PostHog::MCP::Client` for custom dispatchers |
| `rack_middleware.rb` | `Mcp-Session-Id` tokens for a custom Rack stack |
| `sanitization.rb`, `truncation.rb` | Redaction and payload budgets |

Runnable example: [`examples/mcp_server.rb`](../../../examples/mcp_server.rb). Specs:
`spec/posthog/mcp/`.
