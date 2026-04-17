# PostHog Ruby

Please see the main [PostHog docs](https://posthog.com/docs).

Specifically, the [Ruby integration](https://posthog.com/docs/integrations/ruby-integration) details.

> [!IMPORTANT]
> **Use a single client instance (singleton)** — Create the PostHog client once and reuse it throughout your application. Multiple client instances with the same API key can cause dropped events and inconsistent behavior. The SDK will log a warning if it detects multiple instances. For Rails apps, use `PostHog.init` in an initializer (see [posthog-rails](posthog-rails/README.md)).

> [!IMPORTANT]
> Supports Ruby 3.2 and above
>
> We will lag behind but generally not support versions which are end-of-life as listed here https://www.ruby-lang.org/en/downloads/branches/
>
> All 2.x versions of the PostHog Ruby library are compatible with Ruby 2.0 and above if you need Ruby 2.0 support.

## Rails Integration

**Using Rails?** Check out [posthog-rails](posthog-rails/README.md) for automatic exception tracking, ActiveJob instrumentation, and Rails-specific features.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup, example, and test instructions.

For release instructions, see [RELEASING.md](RELEASING.md).
