# PostHog MCP analytics for Ruby

> **Experimental.** `PostHog::MCP` is new and its API, options, and the captured `$mcp_*` event schema may change in a minor release. A one-line warning is logged when you require it. Please report issues at https://github.com/PostHog/posthog-ruby/issues.

Product analytics for [Model Context Protocol](https://modelcontextprotocol.io) servers built on the official Ruby [`mcp`](https://rubygems.org/gems/mcp) gem. Wrap an `MCP::Server` so every tool call, agent intent, handshake, listing, prompt, resource read, and failure is captured to PostHog as a `$mcp_*` event, with the same wire contract as [`@posthog/mcp`](https://github.com/PostHog/posthog-js/tree/main/packages/mcp) (Node) and [`posthog.mcp`](https://github.com/PostHog/posthog-python/tree/master/posthog/mcp) (Python).

```ruby
require 'posthog/mcp'

posthog = PostHog::Client.new(api_key: 'phc_...', host: 'https://us.i.posthog.com')
server = MCP::Server.new(name: 'my-server', version: '1.0.0', tools: [MyTool])
analytics = PostHog::MCP.instrument(server, posthog)
```

Install is just `gem 'posthog-ruby'`. `PostHog::MCP.instrument` needs the `mcp` gem (`>= 1.4`) at runtime, but anyone wrapping a server already has it. `PostHog::MCP::Client` (custom dispatchers, below) needs nothing beyond `posthog-ruby`.

## With posthog-rails

If your app already uses `posthog-rails` and calls `PostHog.init`, the client is resolved for you:

```ruby
# config/initializers/mcp.rb (or wherever you build the server)
require 'posthog/mcp'

PostHog::MCP.instrument(server)
```

## What gets captured

| Event | When |
|---|---|
| `$mcp_initialize` | Client/server handshake (`$mcp_client_name`, `$mcp_client_version`, `$mcp_protocol_version`) |
| `$mcp_tools_list` | Client lists tools (`$mcp_listed_tool_names`; empty lists are flagged as errors) |
| `$mcp_tool_call` | Every tool invocation (`$mcp_tool_name`, `$mcp_parameters`, `$mcp_response`, `$mcp_duration_ms`, `$mcp_is_error`, `$mcp_intent`, ...) |
| `$mcp_prompt_get`, `$mcp_prompts_list`, `$mcp_resource_read`, `$mcp_resources_list` | Prompt and resource traffic |
| `$mcp_missing_capability` | The agent called the `get_more_tools` virtual tool (`report_missing: true`) |
| `$identify` | Once per session when `identify:` resolves a user |
| `$exception` | Sibling of any errored event, in PostHog's error-tracking shape |

Every event carries `$session_id` (a `ses_...` id), `$mcp_source`, `$mcp_server_name`/`$mcp_server_version`, and `$lib: "posthog-ruby-mcp"`. Unlike the Node and Python SDKs, `$lib` is set per event: the client you pass in keeps its own identity (`posthog-ruby` or `posthog-rails`) for everything else it sends.

The full property catalog lives in the [PostHog docs](https://posthog.com/docs/mcp-analytics).

## Options

```ruby
PostHog::MCP.instrument(
  server, posthog,
  identify: ->(request, extra) { { distinct_id: current_user_id(extra), properties: { plan: 'pro' }, groups: { organization: 'org_1' } } },
  event_properties: ->(request, extra) { { deployment: ENV['DEPLOYMENT'] } },
  before_send: ->(payload) { payload['properties'].delete('$mcp_parameters'); payload },
  report_missing: true,
  enable_conversation_id: true,
  logger: ->(message) { Rails.logger.debug(message) }
)
```

| Option | Default | What it does |
|---|---|---|
| `context` | `true` | Inject a required `context` argument into every tool so the agent states why it is calling. Captured as `$mcp_intent`. Pass `false` to disable or `{ description: '...' }` to override the prompt. |
| `intent_fallback` | – | `(request, extra) -> String` used when no `context` argument arrived (`$mcp_intent_source: "inferred"`). |
| `identify` | – | `(request, extra) -> { distinct_id:, properties:, groups: }` or a static Hash. `properties` go to `$set`, `groups` to `$groups`. |
| `event_properties` | – | `(request, extra) -> Hash` spread flat onto every auto-captured event (can override `$mcp_*` keys). |
| `before_send` | – | `(payload) -> payload | nil`, once per emitted payload including `$exception`. Return `nil` to drop. |
| `enable_exception_autocapture` | `true` | Emit the sibling `$exception` for failed calls. |
| `enable_conversation_id` | `false` | Inject `conversation_id`, hand a handle back to the agent, and anchor `$session_id` on it (works across pods and reconnects). |
| `report_missing` | `false` | Advertise the `get_more_tools` virtual tool so agents can report gaps. |
| `missing_capability_tool_name` | `get_more_tools` | Rename the virtual tool. |
| `capture_model` | `false` | Inject `llm_model` and capture `$mcp_llm_model` (client metadata wins over self-report). |
| `logger` | no-op | Sink for the integration's own debug messages. Never writes to stdout. |

The injected arguments are stripped before your tool's `call` receives its keywords. A tool that declares `context` in its own `input_schema` keeps it.

`extra` passed to callbacks contains `'session_id'` (the transport session), `'request_id'`, `'protocol_version'`, `'headers'` (lowercase, HTTP only), and `'session'` (the `MCP::ServerSession`).

## Sessions, stateless HTTP, and multi-pod servers

* **stdio**: one `$session_id` per process, rolled over after 30 minutes of inactivity.
* **Streamable HTTP, stateful**: the transport's `Mcp-Session-Id` is hashed deterministically, so a session survives server restarts.
* **Streamable HTTP, stateless**: the transport issues no session id, so at `initialize` PostHog mints a self-encoded token onto the `Mcp-Session-Id` response header. Clients replay it on every request, and any pod recovers `$session_id` and the client identity from the header alone. This is wired automatically for `MCP::Server::Transports::StreamableHTTPTransport`. For a custom Rack stack add `use PostHog::MCP::RackMiddleware`; the decoded token is exposed as `env['posthog_mcp.session']`.
* **Conversation ids**: `enable_conversation_id: true` derives `$session_id` from the agent's conversation handle, identically on every pod and without any middleware. It is also the only anchor under the 2026-07-28 protocol revision, which removed protocol-level sessions.

When an HTTP request arrives with no session and no token, the integration logs one warning per server explaining how to fix it.

## Custom events

```ruby
analytics = PostHog::MCP.instrument(server, posthog)
analytics.capture('feedback_submitted', { rating: 5 })  # name sent verbatim, on the current session
```

## Custom dispatchers

If you own the HTTP layer and have no `MCP::Server` to wrap, use the client subclass and call the capture methods yourself. It shares the sanitize / truncate / `$exception` pipeline and does not need the `mcp` gem.

```ruby
posthog = PostHog::MCP::Client.new(api_key: 'phc_...', host: 'https://us.i.posthog.com')

tools = posthog.prepare_tool_list(raw_tools, report_missing: true)          # injects `context`, appends get_more_tools
prepared = posthog.prepare_tool_call(name, args)                             # strips `context`, extracts intent
posthog.capture_tool_call(name, intent: prepared.intent, intent_source: prepared.intent_source,
                          duration_ms: 42, is_error: false, distinct_id: 'user_123')
posthog.capture_initialize(client_name: 'claude-code', client_version: '1.2.3', protocol_version: '2025-06-18')
posthog.capture_tools_list(tool_names: tools.map { |t| t[:name] })
posthog.capture_missing_capability(context: prepared.intent) if prepared.is_missing_capability
```

`PostHog::MCP.encode_session_id` / `decode_session_id` implement the `Mcp-Session-Id` token for custom layers, and `PostHog::MCP.derive_session_id_from_conversation` is the cross-SDK session derivation.

## Privacy and payload safety

Before anything is sent: sensitive keys (`authorization`, `api_key`, `token`, `password`, ...) are redacted, PostHog tokens and credential-looking words are masked, image/audio/binary content blocks are replaced with placeholders, structured PII (emails, IPs, card numbers, SSNs, phone numbers) is scrubbed from `$mcp_intent`, and events are truncated to fit the core client's 32KB per-message limit (the Node and Python SDKs budget 100KB; posthog-ruby drops larger messages at batch time, so Ruby truncates harder rather than lose the event). Use `before_send` for anything domain-specific.

## Logging on stdio servers

A stdio MCP server owns `$stdout` for the protocol. The integration's own messages go only to the `logger:` you pass (default: nowhere); the experimental notice and misconfiguration warnings go to stderr. Configure the core SDK's logger away from stdout too: `PostHog::Logging.logger = Logger.new($stderr)`.
