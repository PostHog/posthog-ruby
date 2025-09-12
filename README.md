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

PostHog Ruby now supports comprehensive error tracking with **automatic exception capture** and manual reporting.

### Quick Start

```ruby
require 'posthog'

# Configure PostHog with automatic error tracking
PostHog.configure do |config|
  config.api_key = 'your_api_key_here'
  config.auto_capture_exceptions = true  # Automatically capture all uncaught exceptions
end
```

That's it! All uncaught exceptions in your Rails app, Rack app, Sidekiq jobs, etc. will now be automatically sent to PostHog.

### Automatic Capture

PostHog automatically captures exceptions from:

- **Rails applications** - Controllers, views, and background jobs
- **Rack applications** - Any Rack-based framework (Sinatra, etc.)
- **Sidekiq jobs** - Background job failures with job context
- **DelayedJob jobs** - Background job failures with job details
- **ActionMailer** - Email delivery failures

#### Rails Configuration

```ruby
# config/initializers/posthog.rb
PostHog.configure do |config|
  config.api_key = ENV['POSTHOG_API_KEY']
  config.auto_capture_exceptions = true
  
  # Customize ignored exceptions (optional)
  config.ignored_exceptions = [
    'ActionController::RoutingError',
    'ActiveRecord::RecordNotFound',
    /4\d{2}/  # Ignore 4xx HTTP errors
  ]
end
```

#### Non-Rails Apps

```ruby
# Add PostHog middleware to your Rack app
require 'posthog'

PostHog.configure do |config|
  config.api_key = 'your_api_key'
  config.auto_capture_exceptions = true
end

# Sinatra
class MyApp < Sinatra::Base
  use PostHog::Rack::Middleware
end

# Or any Rack app
use PostHog::Rack::Middleware
```

### Manual Exception Reporting

For handled exceptions or custom error reporting:

```ruby
begin
  risky_operation()
rescue StandardError => e
  PostHog.capture_exception(e, distinct_id: 'user_123')
end
```

#### With Rich Context

```ruby
PostHog.capture_exception(e, {
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
```

#### Custom Error Grouping

```ruby
PostHog.capture_exception(e, {
  distinct_id: 'user_789',
  exception_fingerprint: 'payment_validation_error',  # Custom grouping
  handled: true  # Mark as handled exception
})
```

### Rails Helper Methods

In Rails controllers, you get convenient helper methods:

```ruby
class ApplicationController < ActionController::Base
  # Capture exception with automatic Rails context
  def handle_error(exception)
    posthog_capture_exception(exception, {
      tags: { controller: controller_name, action: action_name },
      extra: { user_plan: current_user&.plan }
    })
  end
  
  # Track events with user context
  def track_signup
    posthog_capture('user_signed_up', { plan: params[:plan] })
  end
  
  # Identify users automatically
  def after_sign_in
    posthog_identify({ name: current_user.name, email: current_user.email })
  end
end
```

### Background Job Integration

#### Sidekiq

Sidekiq integration is automatic when PostHog is configured:

```ruby
class ProcessPaymentJob
  include Sidekiq::Worker

  def perform(user_id, amount)
    # Any exceptions here are automatically captured with job context
    PaymentService.charge_user(user_id, amount)
  end
end
```

#### DelayedJob

DelayedJob integration is also automatic:

```ruby
class EmailJob
  def perform
    # Exceptions automatically captured
    UserMailer.welcome_email.deliver_now
  end
end
```

### Configuration Options

```ruby
PostHog.configure do |config|
  # Required
  config.api_key = 'your_api_key'
  
  # Error tracking (default: false, enabled when api_key is set)
  config.auto_capture_exceptions = true
  
  # Ignore specific exceptions (default: sensible Rails exceptions)
  config.ignored_exceptions = [
    'ActionController::RoutingError',
    'ActiveRecord::RecordNotFound', 
    /4\d{2}/,  # Regex patterns supported
    CustomError  # Exception classes supported
  ]
  
  # Environment-specific settings
  case Rails.env
  when 'development'
    config.auto_capture_exceptions = false  # Disable in development
  when 'test'
    config.test_mode = true
  end
end
```

See `error_tracking_example.rb` for more detailed examples and patterns.

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
