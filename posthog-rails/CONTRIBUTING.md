# Contributing

This guide covers package-specific development for `posthog-rails`.

For repository-level setup, see the root [CONTRIBUTING.md](../CONTRIBUTING.md).

## CI-aligned checks

Run the same checks CI uses before opening a PR:

```bash
bundle exec rspec
bundle exec rubocop
```

## Pull requests

Please keep changes focused, update tests when behavior changes, and follow the existing package conventions.
