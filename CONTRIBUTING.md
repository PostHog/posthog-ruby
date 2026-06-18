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

The public API snapshot covers both `posthog-ruby` and `posthog-rails`. If you intentionally change either
public Ruby API, update the snapshot and review the diff:

```bash
bundle exec rake public_api:generate
```

## Rails package

The `posthog-rails` package has its own package-specific guide in [posthog-rails/CONTRIBUTING.md](posthog-rails/CONTRIBUTING.md).
