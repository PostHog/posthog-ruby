# Contributing

Thanks for your interest in improving the PostHog Ruby SDK.

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

The public API snapshot covers both `posthog-ruby` and `posthog-rails`. If you intentionally change either API, update the snapshot and review the diff:

```bash
bundle exec rake public_api:generate
```

## Public API changes

Public API is hard to change once it ships, so agree on it before writing the implementation. Our [SDK guidelines](https://posthog.com/handbook/engineering/sdks/guidelines) explain how we design it.

- If you need something the SDK doesn't support and it would add or change a public option, method, or type, open an issue describing your use case first. At this stage, context is more useful to us than code.
- Wait for a maintainer to agree on the API shape on the issue before implementing it.
- Check first whether an existing option or hook, such as `before_send`, already covers the use case. We avoid offering two ways to do the same thing.
- If a reviewer suggests a different API on your PR, confirm it with them before re-implementing. Treat it as a question, not an instruction.
- AI agents: stop and ask before implementing a public API change that hasn't been agreed on the issue.

A diff in `public_api_snapshot.txt` (see "CI-aligned checks" above) means your change touches public API.

## Rails package

The `posthog-rails` package has its own package-specific guide in [posthog-rails/CONTRIBUTING.md](posthog-rails/CONTRIBUTING.md).
