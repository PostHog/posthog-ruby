# PostHog Ruby

Please see the main [PostHog docs](https://posthog.com/docs).

Specifically, the [Ruby integration](https://posthog.com/docs/integrations/ruby-integration) details.

> [!IMPORTANT]
> Supports Ruby 3.2 and above
>
> We will lag behind but generally not support versions which are end-of-life as listed here https://www.ruby-lang.org/en/downloads/branches/
>
> All 2.x versions of the PostHog Ruby library are compatible with Ruby 2.0 and above if you need Ruby 2.0 support.

## Rails Integration

**Using Rails?** Check out [posthog-rails](posthog-rails/README.md) for automatic exception tracking, ActiveJob instrumentation, and Rails-specific features.

## Developing Locally

1. Install `asdf` to manage your Ruby version: `brew install asdf`
1. Install Ruby's plugin via `asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git`
1. Make `asdf` install the required version by running `asdf install`
1. Run `bundle install` to install dependencies

## Running example file

1. Build the `posthog-ruby` gem by calling: `gem build posthog-ruby.gemspec`.
2. Install the gem locally: `gem install ./posthog-ruby-<version>.gem`
3. Run `ruby example.rb`

## Testing

1. Run `bin/test` (this ends up calling `bundle exec rspec`)
2. An example of running specific tests: `bin/test spec/posthog/client_spec.rb:26`

## How to release

Both `posthog-ruby` and `posthog-rails` are released together with the same version number.

1. Create a PR that:
   - Updates `lib/posthog/version.rb` with the new version
   - Updates `CHANGELOG.md` with the changes and current date

2. Add the `release` label to the PR

3. Merge the PR to `main`

4. The release workflow will:
   - Notify the Client Libraries team in Slack
   - Wait for approval via the GitHub `Release` environment
   - Publish both gems to RubyGems (via trusted publishing)
   - Create and push a git tag

5. Approve the release in GitHub when prompted

The workflow handles publishing both `posthog-ruby` and `posthog-rails` in the correct order (since `posthog-rails` depends on `posthog-ruby`).
