# posthog-rails

## 3.17.0

### Minor Changes

- 5c21f66: Add `secret_key` config option and deprecate `personal_api_key`.

  `secret_key` is the new canonical credential for local feature flag evaluation and remote config. It accepts either a Personal API Key (`phx_...`) or a Project Secret API Key (`phs_...`). `personal_api_key` still works as a deprecated alias; when both are supplied, `secret_key` wins.

## 3.16.1

### Patch Changes

- 737acbc: Avoid double-capturing ActiveJob exceptions through the Rails error subscriber.

## 3.16.0

### Minor Changes

- 814c495: Improve error tracking capture signals:

  - `capture_exception` now walks the full `exception.cause` chain (outermost-first, cycle-safe, capped at 50) instead of reporting only the outermost exception; chained causes are tagged with a `chained` mechanism and parent linkage.
  - Exception mechanisms now reflect the capture source: manual captures stay `generic`/`handled: true`, while the Rails middleware, `Rails.error` subscriber, and ActiveJob integrations tag captures as `rails`/`rails_error_reporter`/`active_job` with the correct `handled` flag. `capture_exception` accepts a `mechanism:` keyword.

## 3.15.2

### Patch Changes

- fcc6205: Stop duplicating `distinct_id` inside `/flags` person properties.

## 3.15.1

### Patch Changes

- 1376f19: Retry remote feature flag requests after transient 502 and 504 responses.

## 3.15.0

### Minor Changes

- ffc872d: Enable gzip compression for batch uploads by default.

## 3.14.4

### Patch Changes

- 639d493: Retry feature flag requests on transient network errors (timeouts, connection resets) with backoff, so a one-off blip no longer surfaces a hard error to the caller. The retry count is configurable via the `feature_flag_request_max_retries` option (defaults to 1, set to 0 to opt out).

## 3.14.3

### Patch Changes

- 9300bdf: Stamp `telemetry.sdk.name = "posthog-ruby"` on forwarded logs so PostHog can attribute log volume to the Ruby SDK. Previously these records carried the OpenTelemetry SDK default (`opentelemetry`), so they could not be split out per-SDK the way the mobile SDKs are.

## 3.14.2

### Patch Changes

- 45996be: Clear the feature flag call dedupe cache on shutdown.

## 3.14.1

### Patch Changes

- 8008d60: Test separate package release workflow.

> Historical entries before the changelog split are copied from the shared repository changelog and may include changes that primarily affected `posthog-ruby`. New entries are package-specific.

## 3.14.0

### Minor Changes

- 6a39951: Add configurable flush interval for async event batching.

## 3.13.1

### Patch Changes

- 2f66b28: Handle missing Rails middleware insertion targets with safe fallbacks.

## 3.13.0

### Minor Changes

- 42cc569: Add Rails current user resolver configuration for exception capture.

## 3.12.3

### Patch Changes

- 256e276: Fix Rails initializer load order so `PostHog.init` is available when `posthog-rails` is required.
- 12c09b2: Make flush and shutdown safe for test mode clients with queued events.

## 3.12.2

### Patch Changes

- c051002: Stop sending ignored top-level batch metadata fields and always send event UUIDs, normalizing deprecated message IDs when valid.

## 3.12.1

### Patch Changes

- ae9bca8: Harden async worker, shutdown, queue, and feature flag cache behavior for threaded Ruby and Rails apps.

## 3.12.0

### Minor Changes

- cb50bfb: Add opt-in PostHog Logs support to posthog-rails: set `config.logs_enabled = true` to forward `Rails.logger` output to PostHog Logs over OpenTelemetry (OTLP), automatically correlated with the request's PostHog distinct ID and session ID (and active trace/span when OpenTelemetry tracing is present). Includes a configurable severity filter (`logs_level`), a rate cap (`logs_max_records_per_minute`, default 6,000/min), and a `logs_before_send` callback for scrubbing or dropping records. Relies on the optional OpenTelemetry gems; when they are absent the feature warns once and no-ops.

## 3.11.1

### Patch Changes

- babcd86: Send the canonical `posthog-ruby/<version>` User-Agent on feature flag API requests.

## 3.11.0

### Minor Changes

- 75d279c: Support the `early_exit` option in local feature flag evaluation. When a flag's `filters.early_exit` is `true`, evaluation stops and returns a definitive disabled result as soon as a condition group's property filters match (or it has none) but the rollout percentage excludes the user, instead of falling through to later condition groups. This mirrors the server-side evaluation engine (and posthog-node / posthog-python). Property-mismatch groups still fall through as before, and behavior is unchanged when `early_exit` is unset or `false`.

## 3.10.0

### Minor Changes

- fccb4af: Add a configurable `$is_server` event property (default `true`) so PostHog can identify server-side events. Set `is_server: false` when using posthog-ruby as a client/CLI so the device OS is attributed normally.

## 3.9.5

### Patch Changes

- 798a43b: posthog-rails: exclude `ActionDispatch::Http::MimeNegotiation::InvalidType` from captured exceptions by default. It is raised on malformed `Accept`/`Content-Type` headers (almost always scanner traffic) and mapped to a 406 by Rails, so it is noise rather than an app error.

## 3.9.4

### Patch Changes

- 80e2c13: No-op when the SDK is disabled or the Rails facade is used before initialization.

## 3.9.3

### Patch Changes

- 999bd1c: Initialize disabled no-op clients instead of raising or sending requests when the API key is missing or blank.

## 3.9.2

### Patch Changes

- 669a361: Include group context in the `$feature_flag_called` dedupe key so group-scoped flags fire a separate event for each group a user is evaluated under, instead of being dedup-ed against the first group context the same `(distinct_id, flag, response)` was seen under.

## 3.9.1

### Patch Changes

- d3ecc20: Reject semver values with leading zeros (e.g. `1.07.3`, `01.02.03`) during local feature flag evaluation, per semver 2.0.0 §2. Both override values and flag values are validated; invalid inputs raise `InconclusiveMatchError` so the condition does not match.

## 3.9.0

### Minor Changes

- e3ae2b4: Add internal request context support for Rails so request metadata is applied to captures and exception events during a request, with optional PostHog tracing header support for request-scoped identity/session context. Captures without an explicit distinct_id now use request context when available, otherwise they are sent as personless events with a generated UUID.

## 3.8.1

### Patch Changes

- 4b3c2a8: Accept symbol feature flag keys in flag APIs.

## 3.8.0

### Minor Changes

- fe7e453: feat(flags): support mixed targeting in local evaluation

## 3.7.0

### Minor Changes

- 1ad4f2b: Add `evaluate_flags(distinct_id, …)` returning a `FeatureFlagEvaluations` snapshot, and a `flags:` option on `capture` so a single `/flags` call can power both flag branching and event enrichment per request.

  ```ruby
  snapshot = posthog.evaluate_flags("user-1", flag_keys: ["checkout-redesign"])
  posthog.capture(distinct_id: "user-1", event: "checkout_started", flags: snapshot) if snapshot.enabled?("checkout-redesign")
  ```

  The snapshot exposes `enabled?`, `get_flag`, `get_flag_payload`, plus `only_accessed` / `only([keys])` filter helpers. `flag_keys:` scopes the underlying `/flags` request itself. `enabled?` and `get_flag` fire `$feature_flag_called` events with full metadata (`$feature_flag_id`, `$feature_flag_version`, `$feature_flag_reason`, `$feature_flag_request_id`), deduped through the existing per-distinct_id cache. `get_flag_payload` does not record access or fire an event.

  Deprecates `is_feature_enabled`, `get_feature_flag`, `get_feature_flag_result`, `get_feature_flag_payload`, and `capture(send_feature_flags:)`. They continue to work unchanged but now emit a one-time deprecation warning per method pointing at `evaluate_flags()`. Removal is planned for the next major version.

## 3.6.5

### Patch Changes

- 5546e4d: Trim whitespace from `api_key`, `personal_api_key`, and `host` config values, and default `host` to `https://us.i.posthog.com`.

## 3.6.4

### Patch Changes

- 8f9cf78: Trigger another patch release to verify the Ruby release workflow.

## 3.6.3

### Patch Changes

- d83df86: Simplify Ruby release token usage to retry the automated release flow.

## 3.6.2

### Patch Changes

- f69d97a: Switch the Ruby SDK to automated Changesets-based releases.
  - Multiple instances can cause dropped events and inconsistent behavior
  - Use `disable_singleton_warning: true` when intentionally creating multiple clients (e.g., for different projects)
  - Documentation updated with singleton best practices

## 3.5.5 - 2026-03-04

1. feat: Add semver comparison operators for local feature flag evaluation ([#107](https://github.com/PostHog/posthog-ruby/pull/107))
   - Supports `semver_eq`, `semver_neq`, `semver_gt`, `semver_gte`, `semver_lt`, `semver_lte` for direct comparisons
   - Supports `semver_tilde`, `semver_caret`, `semver_wildcard` for range matching
   - Handles v-prefix, pre-release suffixes, partial versions, and whitespace

## 3.5.4 - 2026-02-15

1. fix: Move Rails generator template to `lib/generators/posthog/templates/` to ensure it's included in the gem package ([#103](https://github.com/PostHog/posthog-ruby/issues/103))

## 3.5.3 - 2026-02-08

1. fix: Fix Railtie middleware insertion crashing on Rails initialization — changed `insert_middleware_after` from a class method to an instance method (matching how Rails executes initializer blocks via `instance_exec`), and removed the unsupported `include?` query on `MiddlewareStackProxy` ([#97](https://github.com/PostHog/posthog-ruby/issues/97))
2. fix: Prevent sending empty batches and handle non-JSON response bodies gracefully in transport layer ([#87](https://github.com/PostHog/posthog-ruby/issues/87))
3. fix: Use `$current_url` property (instead of `$request_url`) so exception URLs appear correctly in the PostHog UI
4. fix: Only include source context lines for in-app exception frames, avoiding unnecessary reads of gem source files ([#88](https://github.com/PostHog/posthog-ruby/issues/88))

## 3.5.2 - 2026-02-06

1. fix: Filter out failed flag evaluations to prevent cached values from being overwritten during transient server errors ([#96](https://github.com/PostHog/posthog-ruby/pull/96))

## 3.5.1 - 2026-02-06

1. Fix `posthog-rails` deployment

## 3.5.0 - 2026-02-05

1. feat: Add posthog-rails gem for automatic Rails exception tracking
   - Automatic capture of unhandled exceptions via Rails middleware
   - Automatic capture of rescued exceptions (configurable)
   - Automatic instrumentation of ActiveJob failures
   - Integration with Rails 7.0+ error reporter
   - Configurable exception exclusion list
   - User context capture from controllers

## 3.4.0 - 2025-12-04

1. feat: Add ETag support for feature flag definitions polling ([#84](https://github.com/PostHog/posthog-ruby/pull/84))

## 3.3.3 - 2025-10-22

1. fix: fallback to API for multi-condition flags with static cohorts ([#80](https://github.com/PostHog/posthog-ruby/pull/80))

## 3.3.2 - 2025-09-26

1. fix: don't sort condition sets with variant overrides to top ([#78](https://github.com/PostHog/posthog-ruby/pull/78))

## 3.3.1 - 2025-09-26

Not used

## 3.3.0 - 2025-09-23

1. feat: add exception capture ([#77](https://github.com/PostHog/posthog-ruby/pull/77))

## 3.2.0 - 2025-08-26

1. feat: Add support for local evaluation of flags that depend on other flags ([#75](https://github.com/PostHog/posthog-ruby/pull/75))

## 3.1.2 - 2025-08-26

1. fix: Add cohort evaluation support for local feature flag evaluation ([#74](https://github.com/PostHog/posthog-ruby/pull/74))

## 3.1.1 - 2025-08-06

1. fix: Pass project API key in `remote_config` requests ([#72](https://github.com/PostHog/posthog-ruby/pull/72))

## 3.1.0 - 2025-08-06

1. feat: make the `send_feature_flags` parameter more declarative and ergonomic

## 3.0.1 - 2025-05-20

1. fix: was warning on absent UUID when capturing ([#67](https://github.com/PostHog/posthog-ruby/pull/67))

## 3.0.0 - 2025-05-20

1. Drops support for Ruby 2.x ([#63](https://github.com/PostHog/posthog-ruby/pull/63))

Version 3.0 of the Ruby SDK drops support for Ruby 2.x. The minimum supported version is now Ruby 3.2.

In previous version `FeatureFlags` was added as a top-level class and was causing conflicts for other folk's applications.

In this change we have properly namespaced all classes within a `PostHog` module. See [#60](https://github.com/PostHog/posthog-ruby/issues/60)

## 2.11.0 – 2025-05-20

1. feat: add before_send function ([#64](https://github.com/PostHog/posthog-ruby/pull/64))

## 2.10.0 – 2025-05-20

1. chore: fix all rubocop errors ([#61](https://github.com/PostHog/posthog-ruby/pull/61))
2. fix: add UUID capture option to capture ([#58](https://github.com/PostHog/posthog-ruby/pull/58))

## 2.9.0 – 2025-04-30

1. Use new `/flags` service to power feature flag evaluation.

## 2.8.1 – 2025-04-18

1. Fix `condition_index` can be null in `/decide` requests

## 2.8.0 – 2025-04-07

1. Add more information to `$feature_flag_called` events for `/decide` requests such as flag id, version, reason, and the request id.

## 2.7.2 – 2025-03-14

1. Fix invocation of shell by ` character

## 2.7.0 – 2025-02-26

1. Add support for quota-limited feature flags

## 2.6.0 - 2025-02-13

1. Add method for fetching decrypted remote config flag payload

## 2.5.1 - 2024-12-19

1. Adds a new, optional `distinct_id` parameter to group identify calls which allows specifying the Distinct ID for the event.

## 2.5.0 - 2024-03-15

1. Adds a new `feature_flag_request_timeout_seconds` timeout parameter for feature flags which defaults to 3 seconds, updated from the default 10s for all other API calls.

## 2.4.3 - 2024-02-29

1. Fix memory leak in PostHog::Client.new

## 2.4.2 - 2024-01-26

1. Remove new relative date operators, combine into regular date operators

# 2.4.1 - 2024-01-09

1. Add default properties for feature flags local evaluation, to target flags by distinct id & group keys.

# 2.4.0 - 2024-01-09

1. Numeric property handling for feature flags now does the expected: When passed in a number, we do a numeric comparison. When passed in a string, we do a string comparison. Previously, we always did a string comparison.
2. Add support for relative date operators for local evaluation.

# 2.3.1 - 2023-08-14

1. Update option doc string to show personal API Key as an option

# 2.3.0 - 2023-02-15

1. Add support for feature flag payloads

# 2.2.0 - 2023-02-08

1. Remove concurrent gem dependency version limitation

# 2.1.0 - 2022-11-14

1. Add support for datetime operators for local feature flag evaluation
2. Add support for variant overrides for local feature flag evaluation

# 2.0.0 - 2022-08-12

Breaking changes:

1. Minimum PostHog version requirement: 1.38
2. Regular feature flag evaluation (i.e. by requesting from your PostHog servers) doesn't require a personal API key.
3. `Client` initialisation doesn't take the `api_host` parameter anymore. Instead, it takes the `host` parameter, which needs to be fully qualified. For example: `https://api.posthog.com` is valid, while `api.posthog.com` is not valid.
4. The log level by default is set to WARN. You can change it to DEBUG if you want to debug the client by running `client.logger.level = Logger::DEBUG`, where client is your initialized `PostHog::Client` instance.
5. Default polling interval for feature flags is now set at 30 seconds. If you don't want local evaluation, don't set a personal API key in the library.
6. Feature flag defaults are no more. Now, if a flag fails to compute for whatever reason, it will return `nil`. Otherwise, it returns either true or false. In case of `get_feature_flag`, it may also return a string variant value.

New Changes:

1. You can now evaluate feature flags locally (i.e. without sending a request to your PostHog servers) by setting a personal API key, and passing in groups and person properties to `is_feature_enabled` and `get_feature_flag` calls.
2. Introduces a `get_all_flags` method that returns all feature flags. This is useful for when you want to seed your frontend with some initial flags, given a user ID.

# 1.3.0 - 2022-06-24

- Add support for running the client in "No-op" mode for testing (https://github.com/PostHog/posthog-ruby/pull/15)

# 1.2.4 - 2022-05-30

- Fix `create_alias` call (https://github.com/PostHog/posthog-ruby/pull/14)

# 1.2.3 - 2022-01-18

- Fix `present?` call (https://github.com/PostHog/posthog-ruby/pull/12)

# 1.2.2 - 2021-11-22

- Add ability to disable SSL verification by passing `skip_ssl_verification` (https://github.com/PostHog/posthog-ruby/pull/11)

# 1.2.1 - 2021-11-19

- Add concurrent-ruby gem dependency (fixes #8)

# 1.1.0 - 2020-12-15

- Change default domain from `t.posthog.com` to `app.posthog.com`
