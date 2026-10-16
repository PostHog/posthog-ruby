# PostHog Ruby on Rails

Please see the main [PostHog docs](https://posthog.com/docs).

SDK usage examples and code snippets live in the official documentation so they stay up to date.

## Documentation

- [Ruby on Rails framework docs](https://posthog.com/docs/libraries/ruby-on-rails)
- [Ruby library docs](https://posthog.com/docs/libraries/ruby)

## OpenTelemetry span context (optional)

With OpenTelemetry tracing already installed, the request context adds
`sessionId` and `posthogDistinctId` to the active recording request span.
It uses the existing tracing headers and `config.use_tracing_headers` setting.

To add the same context to child spans, add this processor to your existing
OpenTelemetry setup before requests start:

```ruby
require 'posthog/otel/context_span_processor'

OpenTelemetry.tracer_provider.add_span_processor(PostHog::ContextSpanProcessor.new)
```

This requires OpenTelemetry SDK 1.0.0 or later. The provider must be an
OpenTelemetry SDK tracer provider. Register the processor once. Keep your existing instrumentation, exporter, and sampler.
The PostHog SDK does not create or replace them, and does not require the
OpenTelemetry gems.

The processor reads the request context when each span starts. The request
context also updates the current span when it reads the headers. This covers
both middleware orders: OpenTelemetry can start the request span before or
after the PostHog request context. Without the processor, the request span
must already be active when the PostHog middleware reads the headers.

An attribute already set on a span takes precedence. Your application can
also replace a fallback value later with `span.set_attribute`. Header values
are untrusted analytics context. Do not use them for authentication or access
control. Missing or disabled IDs add no attributes. Sampled-out spans remain
unchanged. This feature does not create a session, recording, or trace.

Context stays local to each request and is cleared after success or failure.
The span keeps its captured IDs after the request ends. Work in another
thread, fiber, or background job needs a separate supported context transfer;
this processor does not transfer request context. For concurrent async work,
configure Rails isolated execution state for fibers.

The optional Rails log forwarding uses the same request IDs. Its OpenTelemetry
logger also records the active trace and span IDs. Log forwarding has its own
setup below.

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
