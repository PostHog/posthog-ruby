# Contributing

Thanks for your interest in improving the PostHog Ruby SDK.

## Commit signing

This repo requires all commits to be signed. To configure commit signing, see the [PostHog handbook](https://posthog.com/handbook/engineering/security#commit-signing). Set `commit.gpgsign` to `true` in your git config so that every commit is signed, not only the ones you sign by hand.

## Developing locally

1. Install `asdf` to manage your Ruby version: `brew install asdf`
2. Install Ruby's plugin: `asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git`
3. Install the required Ruby version: `asdf install`
4. Install dependencies with the pinned Bundler version (required for RubyGems cooldown enforcement): `gem install bundler -v 4.0.13 && bundle install`

## Running the example file

1. Build the gem:

   ```bash
   gem build posthog-ruby.gemspec
   ```

2. Install it locally:

   ```bash
   gem install ./posthog-ruby-<version>.gem
   ```

3. Run the example:

   ```bash
   ruby example.rb
   ```

## CI-aligned checks

Run the same checks CI uses before opening a PR:

```bash
bundle exec rspec
bundle exec rubocop
bundle exec rake public_api:check
```

The JSON compatibility specs run in separate Ruby processes as part of the default suite.
The real Rails logs export and fork tests require Ruby 3.3+ and the optional OpenTelemetry bundle:

```bash
BUNDLE_GEMFILE=gemfiles/otel.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/otel.gemfile bundle exec rspec
```

Without that bundle, those two integration tests are reported as pending. CI runs both bundles.

CI also runs the full suite with real OpenTelemetry dependencies on stable Ruby and the latest stable Rails eligible under the repository's 7-day RubyGems cooldown. This job sets `RAILS_VERSION='>= 5.2'` and runs `bundle update --all` so the committed lockfile does not keep Rails on an older version. The existing Ruby matrix continues to use the committed lockfiles.

The public API snapshot covers both `posthog-ruby` and `posthog-rails`. If you intentionally change either API, update the snapshot and review the diff:

```bash
bundle exec rake public_api:generate
```

## Public API changes

Public API is hard to change once it ships, so agree on it before writing the implementation. Our [SDK guidelines](https://posthog.com/handbook/engineering/sdks/guidelines) explain how we design it.

This section is for external contributors. PostHog maintainers (members of the PostHog GitHub org) agree on API shape in the PR itself, so they don't need a separate issue.

- **Before you start:** if you need something the SDK doesn't support and it would add or change a public option, method, or type, open an issue describing your use case. Wait for a maintainer to agree on the API shape there before you implement it. Context is more useful to us than code at this stage.
- **Already specified?** If a published [sdk-spec](https://github.com/PostHog/sdk-specs) defines the API, that's the agreement, so you don't need an issue.
- **Already have a PR open?** Don't stop or rewrite it. Call out the public API change at the top of the PR description, and link or open an issue so we can discuss the shape there.
- Check first whether an existing option or hook, such as `before_send`, already covers the use case. We avoid offering two ways to do the same thing.
- If a reviewer suggests a different API on your PR, confirm it with them before re-implementing. Treat it as a question, not an instruction.

A diff in `public_api_snapshot.txt` (see "CI-aligned checks" above) means your change touches public API.

## SDK performance benchmarks

Every PR runs the 20-workload [`sdk-benchmarks/v1` specification](https://github.com/PostHog/.github/blob/04f8421ec4daa7f4066eaeb4c53621ba79ddc3ca/.github/workflows/sdk-benchmark-specification.md) against its merge base and exact head. The same head-side fixtures run against separately built, installed gems. Four independent workload shards keep all six alternating base/head pairs on one runner, with a fresh Ruby process for each workload, measurement pass and repetition. No performance percentage is a CI gate; build, correctness and execution errors remain failures.

The benchmark preparation step installs each checkout's frozen Bundler dependencies (with the repository's RubyGems cooldown), builds its SDK gem, and installs that gem into a fresh external directory. Worker processes use those installed gems, not source imports:

```bash
python3 -B benchmarks/prepare.py /path/to/base /path/to/build/base
python3 -B benchmarks/prepare.py "$PWD" /path/to/build/head
python3 -B benchmarks/test_benchmarks.py
python3 -B benchmarks/check_native.py /path/to/build/head
python3 -B benchmarks/run.py \
  --base /path/to/base --head "$PWD" --build-directory /path/to/build \
  --output /path/to/results --smoke --repetitions 1
```

Omit `--smoke` and use `--repetitions 6` for full measurements. `--shard` selects `flags-single`, `flags-scaling`, `flags-memory` or `capture`; `--filter` selects a workload prefix for debugging and cannot be combined with a shard. Smoke checks retain the complete inventory with smaller operation counts. Full flags allocation passes use the documented smaller counts recorded in `allocation_operations`.

Measurement scope:

- Elapsed time uses `Process.clock_gettime(CLOCK_MONOTONIC)`. CPU uses process time, except enqueue-only workloads use caller-thread time because background serialization has no public enqueue completion signal.
- Allocation passes count Ruby objects with cumulative `GC.stat(:total_allocated_objects)`, including objects later collected and allocations on SDK background threads. Native malloc is excluded. Cumulative allocated bytes are unsupported, not estimated from retained heap. Enqueue-only allocations are also unsupported; completed-delivery workloads measure the full worker pipeline.
- Memory passes sample RSS at the specification's operation checkpoints and before/after work. Linux uses `/proc/self/status`; macOS uses `ps`. Linux lifetime peak RSS uses `VmHWM`; it is explicitly unsupported on macOS. `ObjectSpace.memsize_of_all` reports retained live-object bytes after settling, not total allocator arenas or cumulative allocation volume. Snapshot overhead is part of memory observation. GC runs before/after memory measurement, never inside the workload/checkpoints.
- Eight native threads perform the load scenario under Ruby's GVL; this does not promise eight parallel CPU cores. Load checkpoints join each 32-operation group.
- A coordinator-owned loopback receiver exercises the normal SDK HTTP, batching, byte-size splitting and background-worker paths. Receiver CPU, allocations and retained fixtures are outside the measured Ruby process. Refresh elapsed/allocations include the worker's loopback control request selecting the next generation. No production service or credentials are used.
- Public local-only flag getters and reload APIs are used, with flag-called events disabled. The single-flag getter's deprecation warning occurs during warmup. Capture uses public `batch_size: 100000`, `max_queue_size: 100001`, `flush_interval_seconds: 3600` and `compress_request: false`. Native byte-size batching remains active. Warmup deliveries are verified before counters reset; sequences, payloads, users and final delivery are validated without a rescuing flush for delivery workloads.

Workers have a 120-second deadline. After two timeouts a coordinator finishes the current pair, saves partial diagnostics and fails. Each CI shard has a 12-minute job and a 10-minute measurement deadline, reserving time for upload. Collection has five minutes and rejects incomplete shard coverage. Run duration must be assessed from hosted CI, not concurrent local measurements.

The shared reporter validates raw result schema v1 and produces readable tables plus `comparison.json`. Its comment shortlist requires at least a 5% median change and all six pairs agreeing in direction; it is an informational noise filter, not statistical significance. Missing and unsupported counters remain explicit. The read-only producer workflow is separate from the trusted `workflow_run` publisher; automatic PR comments become active only once that caller workflow is on the default branch.

## Rails package

The `posthog-rails` package has its own package-specific guide in [posthog-rails/CONTRIBUTING.md](posthog-rails/CONTRIBUTING.md).
