# PostHog Ruby

Please see the main [PostHog docs](https://posthog.com/docs).

Specifically, the [Ruby integration](https://posthog.com/docs/integrations/ruby-integration) details.

## Features

- Event tracking (`capture`)
- User identification (`identify`) 
- User aliasing (`alias`)
- Group identification (`group_identify`)
- Feature flag evaluation
- **Error tracking (`capture_exception`)** - New!

> [!IMPORTANT]
> Supports Ruby 3.2 and above
>
> We will lag behind but generally not support versions which are end-of-life as listed here https://www.ruby-lang.org/en/downloads/branches/
>
> All 2.x versions of the PostHog Ruby library are compatible with Ruby 2.0 and above if you need Ruby 2.0 support.
## Developing Locally

1. Install `asdf` to manage your Ruby version: `brew install asdf`
1. Install Ruby's plugin via `asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git`
1. Make `asdf` install the required version by running `asdf install`
1. Run `bundle install` to install dependencies

## Error Tracking

PostHog Ruby now supports error tracking! Capture exceptions with rich context and automatic grouping.

### Basic Usage

```ruby
require 'posthog'

posthog = PostHog::Client.new(api_key: 'your_api_key')

begin
  # Some code that might fail
  risky_operation()
rescue StandardError => e
  posthog.capture_exception(e, distinct_id: 'user_123')
end
```

### Advanced Usage

```ruby
# With tags and extra context
posthog.capture_exception(e, {
  distinct_id: 'user_456',
  tags: { 
    component: 'payment_processor',
    severity: 'high'
  },
  extra: {
    amount: 99.99,
    currency: 'USD',
    transaction_id: 'txn_123'
  }
})

# Custom fingerprinting for better grouping
posthog.capture_exception(e, {
  distinct_id: 'user_789',
  exception_fingerprint: 'custom_error_group_001'
})
```

### Hash Format

```ruby
posthog.capture_exception({
  distinct_id: 'user_999',
  exception: StandardError.new('Something went wrong'),
  handled: false,  # Mark as unhandled
  mechanism_type: 'middleware',
  tags: { environment: 'production' },
  extra: { request_id: 'req_abc123' }
})
```

See `error_tracking_example.rb` for more detailed examples including Rails integration.

## Running example files

1. Build the `posthog-ruby` gem by calling: `gem build posthog-ruby.gemspec`.
2. Install the gem locally: `gem install ./posthog-ruby-<version>.gem`
3. Run `ruby example.rb` for basic usage
4. Run `ruby error_tracking_example.rb` for error tracking examples

## Testing

1. Run `bin/test` (this ends up calling `bundle exec rspec`)
2. An example of running specific tests: `bin/test spec/posthog/client_spec.rb:26`

## How to release

1. Get access to RubyGems from @dmarticus, @daibhin or @mariusandra
2. Update `lib/posthog/version.rb` with the new version & add to `CHANGELOG.md`. Commit the changes:

```shell
git commit -am "Version 1.2.3"
git tag -a 1.2.3 -m "Version 1.2.3"
git push && git push --tags
```

3. Run

```shell
gem build posthog-ruby.gemspec
gem push posthog-ruby-1.2.3.gem
```

3. Authenticate with your RubyGems account and approve the publish!
