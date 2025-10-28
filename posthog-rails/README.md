# PostHog Rails

Official PostHog integration for Ruby on Rails applications. Automatically track exceptions, instrument background jobs, and capture user analytics.

## Features

- 🚨 **Automatic exception tracking** - Captures unhandled and rescued exceptions
- 🔄 **ActiveJob instrumentation** - Tracks background job exceptions
- 👤 **User context** - Automatically associates exceptions with the current user
- 🎯 **Smart filtering** - Excludes common Rails exceptions (404s, etc.) by default
- 📊 **Rails 7.0+ error reporter** - Integrates with Rails' built-in error reporting
- ⚙️ **Highly configurable** - Customize what gets tracked

## Installation

Add to your Gemfile:

```ruby
gem 'posthog-ruby'
gem 'posthog-rails'
```

Then run:

```bash
bundle install
```

**Note:** `posthog-rails` depends on `posthog-ruby`, but it's recommended to explicitly include both gems in your Gemfile for clarity.

## Configuration

Create an initializer at `config/initializers/posthog.rb`:

```ruby
PostHog.init do |config|
  # Required: Your PostHog API key
  config.api_key = ENV['POSTHOG_API_KEY']

  # Optional: Your PostHog instance URL (defaults to https://app.posthog.com)
  config.host = 'https://app.posthog.com'

  # Optional: Personal API key for feature flags
  config.personal_api_key = ENV['POSTHOG_PERSONAL_API_KEY']

  # Rails-specific configuration
  config.auto_capture_exceptions = true           # Capture exceptions automatically
  config.report_rescued_exceptions = true         # Report exceptions Rails rescues
  config.auto_instrument_active_job = true        # Instrument background jobs
  config.capture_user_context = true              # Include user info in exceptions
  config.current_user_method = :current_user      # Method to get current user

  # Add additional exceptions to ignore
  config.excluded_exceptions = ['MyCustomError']

  # Error callback
  config.on_error = proc { |status, msg|
    Rails.logger.error("PostHog error: #{msg}")
  }
end
```

### Environment Variables

The recommended approach is to use environment variables:

```bash
# .env
POSTHOG_API_KEY=your_project_api_key
POSTHOG_PERSONAL_API_KEY=your_personal_api_key  # Optional, for feature flags
```

## Usage

### Automatic Exception Tracking

Once configured, exceptions are automatically captured:

```ruby
class PostsController < ApplicationController
  def show
    @post = Post.find(params[:id])
    # Any exception here is automatically captured
  end
end
```

### Manual Event Tracking

Track custom events anywhere in your Rails app:

```ruby
# Track an event
PostHog.capture(
  distinct_id: current_user.id,
  event: 'post_created',
  properties: { title: @post.title }
)

# Identify a user
PostHog.identify(
  distinct_id: current_user.id,
  properties: {
    email: current_user.email,
    plan: current_user.plan
  }
)

# Track an exception manually
PostHog.capture_exception(
  exception,
  current_user.id,
  { custom_property: 'value' }
)
```

### Background Jobs

ActiveJob exceptions are automatically captured:

```ruby
class EmailJob < ApplicationJob
  def perform(user_id)
    user = User.find(user_id)
    UserMailer.welcome(user).deliver_now
    # Exceptions are automatically captured with job context
  end
end
```

### Feature Flags

Use feature flags in your Rails app:

```ruby
class PostsController < ApplicationController
  def show
    if PostHog.is_feature_enabled('new-post-design', current_user.id)
      render 'posts/show_new'
    else
      render 'posts/show'
    end
  end
end
```

### Rails 7.0+ Error Reporter

PostHog integrates with Rails' built-in error reporting:

```ruby
# These errors are automatically sent to PostHog
Rails.error.handle do
  # Code that might raise an error
end

Rails.error.record(exception, context: { user_id: current_user.id })
```

## Configuration Options

### Core PostHog Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `api_key` | String | **required** | Your PostHog project API key |
| `host` | String | `https://app.posthog.com` | PostHog instance URL |
| `personal_api_key` | String | `nil` | For feature flag evaluation |
| `max_queue_size` | Integer | `10000` | Max events to queue |
| `test_mode` | Boolean | `false` | Don't send events (for testing) |
| `on_error` | Proc | `nil` | Error callback |
| `feature_flags_polling_interval` | Integer | `30` | Seconds between flag polls |

### Rails-Specific Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `auto_capture_exceptions` | Boolean | `true` | Automatically capture exceptions |
| `report_rescued_exceptions` | Boolean | `true` | Report exceptions Rails rescues |
| `auto_instrument_active_job` | Boolean | `true` | Instrument ActiveJob |
| `capture_user_context` | Boolean | `true` | Include user info |
| `current_user_method` | Symbol | `:current_user` | Controller method for user |
| `excluded_exceptions` | Array | `[]` | Additional exceptions to ignore |

### Understanding Exception Tracking Options

**`auto_capture_exceptions`** - Master switch for all automatic error tracking
- When `true`: All exceptions are automatically captured and sent to PostHog
- When `false`: No automatic error tracking (you must manually call `PostHog.capture_exception`)
- **Use case:** Turn off automatic error tracking completely

**`report_rescued_exceptions`** - Control exceptions that Rails handles gracefully
- When `true`: Capture exceptions that Rails rescues and shows error pages for (404s, 500s, etc.)
- When `false`: Only capture truly unhandled exceptions that crash your app
- **Use case:** Reduce noise by ignoring errors Rails already handles

**Example:**

```ruby
# Scenario: User visits /posts/999999 (post doesn't exist)
def show
  @post = Post.find(params[:id])  # Raises ActiveRecord::RecordNotFound
end
```

| Configuration | Result |
|---------------|--------|
| `auto_capture_exceptions = true`<br>`report_rescued_exceptions = true` | ✅ Exception captured (default behavior) |
| `auto_capture_exceptions = true`<br>`report_rescued_exceptions = false` | ❌ Not captured (Rails rescued it) |
| `auto_capture_exceptions = false` | ❌ Not captured (automatic tracking disabled) |

**Recommendation:** Keep both `true` (default) to get complete visibility into all errors. Set `report_rescued_exceptions = false` only if you want to track just critical crashes.

## Excluded Exceptions by Default

The following exceptions are not reported by default (common 4xx errors):

- `AbstractController::ActionNotFound`
- `ActionController::BadRequest`
- `ActionController::InvalidAuthenticityToken`
- `ActionController::RoutingError`
- `ActionDispatch::Http::Parameters::ParseError`
- `ActiveRecord::RecordNotFound`
- `ActiveRecord::RecordNotUnique`

You can add more with `config.excluded_exceptions = ['MyException']`.

## User Context

PostHog Rails automatically captures user information from your controllers:

```ruby
class ApplicationController < ActionController::Base
  # PostHog will automatically call this method
  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end
end
```

If your user method has a different name, configure it:

```ruby
config.current_user_method = :logged_in_user
```

## Sensitive Data Filtering

PostHog Rails automatically filters sensitive parameters:

- `password`
- `password_confirmation`
- `token`
- `secret`
- `api_key`
- `authenticity_token`

Long parameter values are also truncated to 1000 characters.

## Testing

In your test environment, you can disable PostHog or use test mode:

```ruby
# config/environments/test.rb
PostHog.init do |config|
  config.test_mode = true  # Events are queued but not sent
end
```

Or in your tests:

```ruby
# spec/rails_helper.rb
RSpec.configure do |config|
  config.before(:each) do
    allow(PostHog).to receive(:capture)
  end
end
```

## Development

To run tests:

```bash
cd posthog-rails
bundle install
bundle exec rspec
```

## Architecture

PostHog Rails uses the following components:

- **Railtie** - Hooks into Rails initialization
- **Middleware** - Two middleware components capture exceptions:
  - `RescuedExceptionInterceptor` - Catches rescued exceptions
  - `CaptureExceptions` - Reports all exceptions to PostHog
- **ActiveJob** - Prepends exception handling to `perform_now`
- **Error Subscriber** - Integrates with Rails 7.0+ error reporter

## Troubleshooting

### Exceptions not being captured

1. Verify PostHog is initialized:
   ```ruby
   Rails.console
   > PostHog.initialized?
   => true
   ```

2. Check your excluded exceptions list
3. Verify middleware is installed:
   ```ruby
   Rails.application.middleware
   ```

### User context not working

1. Verify `current_user_method` matches your controller method
2. Check that the method returns an object with an `id` attribute
3. Enable logging to see what's being captured

### Feature flags not working

Ensure you've set `personal_api_key`:

```ruby
config.personal_api_key = ENV['POSTHOG_PERSONAL_API_KEY']
```

## Contributing

See the main [PostHog Ruby](../README.md) repository for contribution guidelines.

## License

MIT License. See [LICENSE](../LICENSE) for details.
