# PostHog Ruby on Rails

Please see the main [PostHog docs](https://posthog.com/docs).

SDK usage examples and code snippets live in the official documentation so they stay up to date.

## Documentation

- [Ruby on Rails framework docs](https://posthog.com/docs/libraries/ruby-on-rails)
- [Ruby library docs](https://posthog.com/docs/libraries/ruby)

## Exception stack frames

Rails-generated template method names lose their unstable numeric suffixes when they match the template source path. File paths, line numbers, source context, and application-frame classification stay unchanged; no additional frames are silenced or removed.

## OpenTelemetry span context (optional)

Request context adds missing `sessionId` and `posthogDistinctId` attributes to an active recording OpenTelemetry SDK span. Register the optional `PostHog::ContextSpanProcessor` on the application's existing provider for child spans. OpenTelemetry SDK 1.0.0 or later is supported and remains optional.

The request keeps the Rails facade client that owned it at entry. A missing or disabled owner adds no PostHog span attributes. A valid-key test-mode client remains enabled.

Existing canonical attributes take precedence. Missing IDs stay absent. Spans keep their captured IDs after the request ends. Separate threads and fibers need explicit context transfer; concurrent Rails fibers require fiber-isolated execution state.

See the [Rails trace context guide](https://posthog.com/docs/libraries/ruby-on-rails#trace-context) for setup, middleware order, and trust limits. The bridge does not replace the application's provider, exporter, or sampler. Optional Rails log forwarding uses the same request context.

## Controller exception reporting

Controllers and API controllers gain a private `capture_exception(exception, distinct_id = nil, additional_properties = {}, flags: nil, mechanism: nil)` helper. Existing controller helpers with that name are not replaced. It returns the core capture result (`true`, `false`, or `nil`) and is not a controller action.

The existing `PostHog.capture_exception` API remains available. This helper keeps configured-user resolution, controller/action and filtered parameters local to an explicit exception-reporting call rather than adding them to every event through `RequestContext`.

Manual reports do not require `auto_capture_exceptions` and do not apply automatic exception exclusions. They retain the core manual handled-exception defaults and duplicate prevention. Missing or disabled clients no-op without initializing a client.

These remain plain manual captures: the default mechanism is `generic` with `handled: true`, and the helper does not add `$exception_source`. Adding Rails context does not introduce a new automatic capture boundary.

Explicit identity wins over the configured current user, then request identity. Explicit properties win over inferred request properties. The helper respects `capture_user_context`, current-user resolution settings, and `use_tracing_headers`. Request parameters use Rails `filter_parameters`; automatically derived URLs omit queries and fragments. Explicit properties and exception messages are not parameter-filtered. Unavailable or malformed enrichment is omitted without dropping the original report or replacing application exceptions. Request context is not retained after the request.

Manual reports use already-parsed Rails parameter/body caches, with query/path parameters as fallback. The helper does not proactively parse uncached bodies; richer body collection is outside this helper. Rails may independently parse or log bodies before an action runs; the helper does not suppress framework-owned diagnostics. A response status is included only when already known, including after a controller has performed its response; the default pre-response status is not inferred.

## Streaming exceptions

With `auto_capture_exceptions` enabled (default `false`), errors reported by ActionController::Live and ActionView streaming templates are captured through the existing exception pipeline, respecting excluded exceptions and duplicate prevention. Rails logging and streaming completion behavior are unchanged.

Live reporters rebuild context from their controller's own filtered request data and headers only while reporting, restoring any ambient context afterward without annotating ambient spans. Authenticated controller identity still takes precedence over header identity. Streaming template bodies use only the context active when Rails reports the error; they do not retain the context from body creation. Errors enumerated after request middleware exits may therefore lack request identity and metadata. Identity is not automatically transferred across arbitrary application-created threads or fibers.

## Active Job context

Set `config.auto_instrument_active_job = true` to copy the current session and distinct IDs into queued Active Job data. Each job runs with its saved IDs in a fresh context. Request properties are excluded. The context is restored after success, an error, or a retry. Older jobs without saved IDs run with empty context.

The existing job distinct ID extractor takes precedence over the saved ID. Rescue, discard, and terminal retry handlers keep this effective context, including when they enqueue child jobs. Integer and finite floating-point distinct IDs are stored as strings in job snapshots; session IDs must be strings. Events, optional logs, and application OpenTelemetry spans use the shared job context. Register `PostHog::ContextSpanProcessor` for child spans as described in the trace context guide. An existing job span receives IDs only when its public `messaging.system` is `active_job` and `messaging.message.id` matches the current job ID. Other active spans stay unchanged. This transfers PostHog IDs; it does not transfer a distributed trace or configure a tracing provider.

## Sidekiq retry reporting (optional)

On Rails 7.1 or later with Sidekiq 7.0.3 or later, explicitly load and install the integration in an initializer:

```ruby
require 'posthog/rails/sidekiq'

Sidekiq.configure_server do |config|
  PostHog::Rails::Sidekiq.install(config, error_reporting: :exhausted)
end
```

Initialize the PostHog client with `PostHog.init` as usual. Installation is independent of Rails' `auto_capture_exceptions` option. There is no Sidekiq setting on `PostHog::Rails::Configuration`, and the optional integration is not loaded by the general Rails integration. Leaving it uninstalled keeps existing reporting unchanged.

The required `error_reporting:` argument accepts:
- `:all` reports each failed Sidekiq attempt once through Sidekiq's error handler.
- `:exhausted` reports Sidekiq's terminal failure notifications through its death handler. This includes exhausted retries, early kills, jobs with `retry: false`, and terminal failures with `dead: false`.
- `:dead` reports only terminal failures sent to Sidekiq's dead queue. It skips `retry: false`, `dead: false`, and discarded jobs. `retry: 0` can still send a failed job to the dead queue.

Sidekiq 7.0.3+ labels its Rails 7.1+ error reports with `job.sidekiq`, distinguishing Sidekiq failures from unrelated Rails reports. These policies follow Sidekiq's callbacks, not a comparison of retry counts. In Sidekiq 8.1+, deliberate discards also emit a terminal failure notification and are included in `:exhausted`. Earlier versions do not notify death handlers for these discards.

The installed Sidekiq integration owns automatic error reporting for its jobs. Rails wrapper reports and Active Job captures defer to the selected Sidekiq policy instead of sending separate events. Active Job identity, session, filtered job properties, and correlation IDs from an active span are retained when available. Tracing remains optional and spans are not kept open for deferred reporting. When nested Active Jobs propagate the same exception, its first reporting job owns the deferred context; a newly raised wrapper exception retains its own job context. Other Rails error subscribers and Sidekiq handlers remain active. Manual exception captures and explicit application Rails error reports are not filtered by this policy. Active Job's own retry scheduling still controls failures it consumes before they reach Sidekiq.

The integration does not change retry scheduling, dead-queue storage, or shutdown handling. Native Sidekiq job arguments are not collected, and Sidekiq infrastructure errors without a job are not captured by these hooks. Sidekiq remains an optional application dependency. Unsupported Rails or Sidekiq versions log a warning and keep the existing reporting paths. Install at boot, not while jobs are running. Reinstalling on the same server configuration updates the policy without adding duplicate handlers.

## Action Cable exceptions

`auto_capture_exceptions` (default: false) also captures exceptions escaping Action Cable connection open/close, channel subscribe/unsubscribe callbacks, and dispatched channel actions. `excluded_exceptions` applies. Action Cable stays optional and loads lazily; no spans are created or enriched.

Each operation uses fresh connection-env context owned by the current Rails facade client and restores the caller's context on exit. Sanitized PostHog headers provide session and fallback identity unless `use_tracing_headers` is false. Explicit capture IDs/properties retain precedence.

Exception identity prefers authenticated controller context from the environment. Without a controller, the connection's `current_user_method` and existing `user_id_method`/common ID rules apply. `capture_user_context = false` disables lookup; unavailable users fall back to headers. `current_user_resolver` retains its controller-only contract and is not called with a connection. Connection identifiers and cookies never infer identity.

Properties include connection/channel classes, operation, and channel params/action data filtered by both application `filter_parameters` and the effective connection's `config.filter_parameters` (including Cable-specific rules). Nested values and Rails-supported Proc filters apply before serialization. Raw environments, cookies, authorization headers, subscription identifiers, and URL query strings are not attached. Review filtering and `before_send` for application-specific sensitive data.

Channel failures dispatched through `Subscriptions#execute_command` wait for connection `rescue_from` handling before capture. Application-consumed exceptions, including channel-local and connection `rescue_from`, are not captured by these boundaries, even with `report_rescued_exceptions = true`. That option does not enable handled Action Cable events. Unhandled channel failures retain channel/action context, including when the dispatcher logs them without re-raising. Direct channel calls capture escaping errors without invoking connection handlers. Return values, handler invocation counts, and escaping exceptions remain unchanged.

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

Structured notification logs are separately opt-in with `config.logs_notifications`
(default `[]`), selecting `:action_controller`, `:active_record`, `:active_job`,
and/or `:action_mailer`. Components register lazily without loading optional Rails
packages. `logs_enabled` remains the master gate; notification records share the
forwarding threshold, rate cap, hook, correlation, and shutdown pipeline. Set
`logs_forward_rails_logger` to `false` to collect notifications without also
forwarding generic logger lines. SQL records use debug severity; successful
controller/job/mailer records use info, controller 4xx responses warn, and failures
error. Error-bearing retry notifications also use error severity: they describe a
failed attempt, not necessarily terminal job failure. `rails.job.retry_wait` is
reported in seconds, including waits supplied as `ActiveSupport::Duration`.
These records do not create spans or collect timings.

Notification bodies are fixed descriptions with allowlisted event metadata.
`rails.params` serializes Rails' already-filtered controller notification parameters
without applying filters again. `rails.job.arguments` applies the application's
`filter_parameters` to copied original key/value types before JSON normalization.
Unkeyed job arguments are redacted; jobs with `log_arguments = false` and Action
Mailer delivery jobs omit arguments entirely. Unsupported, cyclic, or oversized
parameter trees are wholly redacted rather than partially truncated. Unencodable
or oversized JSON payloads are replaced with a redaction marker without dropping
the lifecycle record. An empty `filter_parameters` list redacts keyed job payloads
rather than exporting them unfiltered.
SQL statements/binds, cookies/headers, and mail recipients/subject/content are not
collected. Review configured parameter filters and use `logs_before_send` for
additional scrubbing. Job completion records reuse saved/effective job identity
only when the existing `auto_instrument_active_job` integration is enabled; logging
alone does not enable job context propagation or exception capture.

To exercise real controller and inline job notifications against your project:

```bash
POSTHOG_API_KEY='<project_api_key>' POSTHOG_HOST='https://us.i.posthog.com' \
  BUNDLE_GEMFILE=gemfiles/otel.gemfile bundle exec ruby examples/rails_notification_logs.rb
```

Run from the repository root after installing the OpenTelemetry bundle. The example
checks outgoing record counts and filtering, then prints a unique run ID to find
its eight analytics events and eleven records in PostHog Logs. Controller responses
exercise info, warn, and error severity; the hook drops the 418 controller record.
SQL and mailer notifications are not exercised by this example.

Known limitations of the broadcast approach:

- `Rails.logger.silence` does not silence forwarding — silenced records still
  ship to PostHog (the silencer only lowers the level of loggers that support
  `local_level`).
- `Rails.logger.tagged` tags (including `config.log_tags` request IDs) are not
  attached to forwarded records, and the non-block form
  (`Rails.logger.tagged('X')`) returns a logger that bypasses forwarding
  entirely.
