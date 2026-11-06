# PostHog Ruby on Rails

Please see the main [PostHog docs](https://posthog.com/docs).

SDK usage examples and code snippets live in the official documentation so they stay up to date.

## Documentation

- [Ruby on Rails framework docs](https://posthog.com/docs/libraries/ruby-on-rails)
- [Ruby library docs](https://posthog.com/docs/libraries/ruby)

## OpenTelemetry span context (optional)

Request context adds missing `sessionId` and `posthogDistinctId` attributes to an active recording OpenTelemetry SDK span. Register the optional `PostHog::ContextSpanProcessor` on the application's existing provider for child spans. OpenTelemetry SDK 1.0.0 or later is supported and remains optional.

The request keeps the Rails facade client that owned it at entry. A missing or disabled owner adds no PostHog span attributes. A valid-key test-mode client remains enabled.

Existing canonical attributes take precedence. Missing IDs stay absent. Spans keep their captured IDs after the request ends. Separate threads and fibers need explicit context transfer; concurrent Rails fibers require fiber-isolated execution state.

See the [Rails trace context guide](https://posthog.com/docs/libraries/ruby-on-rails#trace-context) for setup, middleware order, and trust limits. The bridge does not replace the application's provider, exporter, or sampler. Optional Rails log forwarding uses the same request context.

## Exception context

Sensitive request collection is disabled by default: `exception_request_headers` and `exception_request_cookies` are empty name allowlists, and `exception_request_body` is false. These options add `$request_headers`, `$request_cookies`, and `$request_body` only to automatic request middleware exception captures, never to ordinary analytics events or forwarded logs. Header names are case-insensitive and emitted lowercase with hyphens; header filter Procs see these canonical String keys, not configured spelling or Rack environment keys. Cookie names are case-sensitive and cookie filter Procs see the original String names. Entire Cookie/Set-Cookie headers are excluded even if allowlisted. Values respect the application's Rails `filter_parameters`; review those filters before opting in.

Body collection accepts JSON objects/arrays and URL-encoded forms only, up to 10,000 bytes. Malformed, oversized, multipart, raw-text, and non-seekable/streaming inputs are omitted. Seekable input positions are restored, including after errors. Existing filtered `$request_params` remain available independently of the new body option: cached Rails parameters are filtered without reparsing; uncached bodies use the same bounded JSON/form parser, merged with query and path parameters in Rails precedence order. Uncached oversized or unsupported bodies are omitted rather than invoking Rails parsers that may log raw malformed input.

When Rails provides `ActiveSupport::ExecutionContext` (Rails 7+), automatic request, job, and error-reporter exception paths attach a filtered `$execution_context` snapshot at the capture boundary. Context is not transferred into queued jobs or retained by this integration. Context already unwound before capture cannot be recovered. Error-reporter metadata is also filtered. Metadata uses capability-detected GlobalID strings, then class/ID references, never model attribute hashes; unknown objects use class markers. GlobalID remains optional.

Before filtering, metadata is copied without normalizing keys or scalar types/encodings and without truncating values. Custom Rails filters receive the original key types and complete supported values/root data. Allowlisted header values are filtered before any value normalization. Cyclic or oversized metadata, including hashes with callable defaults, is discarded as a whole (fields may be empty) rather than running filters on partial data, including oversized cached request parameters. Limits are depth 10, 100 entries per container, 1,000 visited keys/values, 10,000 bytes per string and a shared 32,768-byte string-content budget per metadata field. Final JSON normalization remains bounded after filtering. Existing identity precedence, deduplication, transport and `before_send` hooks are unchanged; use `before_send` for additional application-specific scrubbing.

## Active Job context

Set `config.auto_instrument_active_job = true` to copy the current session and distinct IDs into queued Active Job data. Each job runs with its saved IDs in a fresh context. Request properties are excluded. The context is restored after success, an error, or a retry. Older jobs without saved IDs run with empty context.

The existing job distinct ID extractor takes precedence over the saved ID. Rescue, discard, and terminal retry handlers keep this effective context, including when they enqueue child jobs. Integer and finite floating-point distinct IDs are stored as strings in job snapshots; session IDs must be strings. Events, optional logs, and application OpenTelemetry spans use the shared job context. Register `PostHog::ContextSpanProcessor` for child spans as described in the trace context guide. An existing job span receives IDs only when its public `messaging.system` is `active_job` and `messaging.message.id` matches the current job ID. Other active spans stay unchanged. This transfers PostHog IDs; it does not transfer a distributed trace or configure a tracing provider.

## PostHog Logs (optional)

`posthog-rails` can forward `Rails.logger` output to [PostHog Logs](https://posthog.com/docs/logs)
over OpenTelemetry (OTLP), automatically correlated with the request's PostHog
distinct ID and session ID.

This is opt-in and relies on the standard OpenTelemetry gems (Ruby 3.3+), which
are not bundled. Add them to your `Gemfile`:

```ruby
gem 'opentelemetry-sdk', require: false
gem 'opentelemetry-logs-sdk', '>= 0.6.0', require: false
gem 'opentelemetry-exporter-otlp-logs', require: false
```

`opentelemetry-logs-sdk` must be `>= 0.6.0`: the OTLP logs exporter encodes
`LogRecordData#event_name`, which only exists from 0.6.0 onward, so older
pairings raise a `NoMethodError` when exporting. (0.6.0 also requires Ruby 3.3+.)

`require: false` keeps the gems off the boot path — `posthog-rails` requires
them only when logs are enabled. It also avoids `opentelemetry-logs-sdk`'s
load-time `Configurator` patch, which would otherwise piggyback a second logs
pipeline onto an existing `OpenTelemetry::SDK.configure` (tracing) call.

Then enable it in `config/initializers/posthog.rb`:

```ruby
PostHog::Rails.configure do |config|
  config.logs_enabled = true
end
```

When the OpenTelemetry gems are absent, the feature logs a single warning and
no-ops, so it is safe to enable conditionally.

Forwarding is capped at 6,000 records per minute by default to protect your
ingestion quota from runaway log volume; when the cap trips, one warning record
is emitted and further records are dropped for the remainder of the window.
Tune or disable it with `config.logs_max_records_per_minute` (set to `nil` or
`0` to disable; numeric strings such as ENV values are coerced).

To scrub PII (or drop records entirely) before they leave the app, set
`config.logs_before_send` to a proc that receives each record hash and returns
a modified hash to send or `nil` to drop it. If the callback raises, the
record is dropped.

If your app already uses OpenTelemetry tracing, log records emitted during a
traced request automatically carry the active `trace_id`/`span_id` — no
configuration needed.

`config.logs_level` filters what is forwarded to PostHog; it never changes
what your app logs. Setting it below the Rails logger level (e.g. `:debug`
with an `:info` app) does not make Rails or ActiveRecord generate extra
output — only records the app actually produces are forwarded.

Known limitations of the broadcast approach:

- `Rails.logger.silence` does not silence forwarding — silenced records still
  ship to PostHog (the silencer only lowers the level of loggers that support
  `local_level`).
- `Rails.logger.tagged` tags (including `config.log_tags` request IDs) are not
  attached to forwarded records, and the non-block form
  (`Rails.logger.tagged('X')`) returns a logger that bypasses forwarding
  entirely.
