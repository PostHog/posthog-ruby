# PostHog Rails Implementation Summary

This document provides an overview of the posthog-rails gem implementation, following the Sentry Rails integration pattern.

## Architecture Overview

PostHog Rails is a separate gem that provides Rails-specific integrations for the core `posthog-ruby` SDK. It follows a monorepo pattern where both gems live in the same repository but are published separately.

## Directory Structure

```
posthog-rails/
├── lib/
│   ├── posthog-rails.rb                    # Main entry point
│   └── posthog/
│       └── rails/
│           ├── rails.rb                    # Module definition & requires
│           ├── railtie.rb                  # Rails integration hook
│           ├── configuration.rb            # Rails-specific config
│           ├── capture_exceptions.rb       # Exception capture middleware
│           ├── rescued_exception_interceptor.rb  # Rescued exception middleware
│           ├── active_job.rb               # ActiveJob instrumentation
│           └── error_subscriber.rb         # Rails 7.0+ error reporter
├── examples/
│   └── posthog.rb                          # Example initializer
├── posthog-rails.gemspec                   # Gem specification
├── README.md                               # User documentation
└── IMPLEMENTATION.md                       # This file
```

## Component Descriptions

### 1. Gemspec (`posthog-rails.gemspec`)

Defines the gem and its dependencies:
- Depends on `posthog-ruby` (core SDK)
- Depends on `railties >= 5.2.0` (minimal Rails dependency)
- Version is synced with posthog-ruby

### 2. Main Entry Point (`lib/posthog-rails.rb`)

Simple entry point that:
- Requires the core `posthog-ruby` gem
- Requires `posthog/rails` if Rails is defined

### 3. Rails Module (`lib/posthog/rails.rb`)

Loads all Rails-specific components in the correct order:
1. Configuration
2. Middleware components
3. ActiveJob integration
4. Error subscriber
5. Railtie (must be last)

### 4. Railtie (`lib/posthog/rails/railtie.rb`)

The core Rails integration hook that:

#### Adds Module Methods
- Extends `PostHog` module with class methods
- Adds `PostHog.init` configuration block
- Adds delegation methods (`capture`, `capture_exception`, etc.)
- Stores singleton `client` and `rails_config`

#### Middleware Registration
Inserts two middleware in the Rails stack:
```ruby
ActionDispatch::DebugExceptions
  ↓
PostHog::Rails::RescuedExceptionInterceptor  # Catches exceptions early
  ↓
Application Code
  ↓
ActionDispatch::ShowExceptions
  ↓
PostHog::Rails::CaptureExceptions           # Reports to PostHog
```

#### ActiveJob Hook
Uses `ActiveSupport.on_load(:active_job)` to prepend exception handling module before ActiveJob loads.

#### After Initialize
- Configures Rails environment (logger, etc.)
- Registers Rails 7.0+ error subscriber
- Sets up graceful shutdown

### 5. Configuration (`lib/posthog/rails/configuration.rb`)

Rails-specific configuration options:
- `auto_capture_exceptions` - Enable/disable automatic capture
- `report_rescued_exceptions` - Report exceptions Rails rescues
- `auto_instrument_active_job` - Enable/disable job instrumentation
- `excluded_exceptions` - Additional exceptions to ignore
- `capture_user_context` - Include user info
- `current_user_method` - Controller method name for user

Also includes:
- Default excluded exceptions list (404s, parameter errors, etc.)
- `should_capture_exception?` method for filtering

### 6. CaptureExceptions Middleware (`lib/posthog/rails/capture_exceptions.rb`)

Main exception capture middleware that:
1. Wraps application call in exception handler
2. Checks for exceptions in `env` from Rails or other middleware
3. Filters exceptions based on configuration
4. Extracts user context from controller
5. Builds request properties (URL, method, params, etc.)
6. Filters sensitive parameters
7. Calls `PostHog.capture_exception`

**User Context Extraction:**
- Gets controller from `env['action_controller.instance']`
- Calls configured user method (default: `current_user`)
- Extracts ID from user object
- Falls back to session ID if no user

**Request Context:**
- Request URL, method, path
- Controller and action names
- Filtered request parameters
- User agent and referrer

### 7. RescuedExceptionInterceptor Middleware (`lib/posthog/rails/rescued_exception_interceptor.rb`)

Lightweight middleware that:
- Catches exceptions before Rails rescues them
- Stores in `env['posthog.rescued_exception']`
- Re-raises the exception (doesn't suppress it)
- Only runs if `report_rescued_exceptions` is enabled

This ensures we capture exceptions that Rails handles with `rescue_from` or similar.

### 8. ActiveJob Integration (`lib/posthog/rails/active_job.rb`)

Module prepended to `ActiveJob::Base`:
- Wraps `perform_now` method
- Catches exceptions during job execution
- Extracts job context (class, ID, queue, priority)
- Tries to extract user ID from job arguments
- Sanitizes job arguments (filters sensitive data)
- Calls `PostHog.capture_exception`

**Argument Sanitization:**
- Keeps primitives (string, integer, boolean, nil)
- Filters sensitive hash keys
- Converts ActiveRecord objects to `{class, id}`
- Replaces complex objects with class name

### 9. Error Subscriber (`lib/posthog/rails/error_subscriber.rb`)

Rails 7.0+ integration:
- Subscribes to `Rails.error` reporter
- Receives errors from `Rails.error.handle` and `Rails.error.record`
- Captures error with context
- Includes handled/unhandled status and severity

## Exception Flow

### HTTP Request Exceptions

```
1. User makes request
   ↓
2. RescuedExceptionInterceptor catches and stores exception
   ↓
3. Exception bubbles up through Rails
   ↓
4. Rails may rescue it (rescue_from, etc.)
   ↓
5. Rails stores in env['action_dispatch.exception']
   ↓
6. CaptureExceptions middleware checks env for exception
   ↓
7. Extracts user and request context
   ↓
8. Filters based on configuration
   ↓
9. Calls PostHog.capture_exception
   ↓
10. Response returned to user
```

### ActiveJob Exceptions

```
1. Job.perform_later called
   ↓
2. ActiveJob enqueues job
   ↓
3. Worker picks up job
   ↓
4. Calls perform_now (our wrapped version)
   ↓
5. Exception raised in perform
   ↓
6. Our module catches it
   ↓
7. Extracts job context
   ↓
8. Calls PostHog.capture_exception
   ↓
9. Re-raises exception for normal job error handling
```

## User Experience

### Installation
```bash
# Gemfile
gem 'posthog-rails'

bundle install
```

### Configuration
```ruby
# config/initializers/posthog.rb
PostHog.init do |config|
  config.api_key = ENV['POSTHOG_API_KEY']
  config.personal_api_key = ENV['POSTHOG_PERSONAL_API_KEY']

  # Rails options
  config.auto_capture_exceptions = true
  config.current_user_method = :current_user
end
```

### Usage
```ruby
# Automatic - just works!
class PostsController < ApplicationController
  def show
    @post = Post.find(params[:id])
    # Exceptions automatically captured
  end
end

# Manual tracking
PostHog.capture(
  distinct_id: current_user.id,
  event: 'post_viewed'
)
```

## Key Design Decisions

### 1. Separate Gem
Following Sentry's pattern, posthog-rails is a separate gem. Benefits:
- Non-Rails users don't get Rails bloat
- Clear separation of concerns
- Independent versioning possible
- Rails-specific features don't affect core

### 2. Middleware-Based Capture
Using middleware instead of monkey-patching:
- More reliable
- Works with any exception handling strategy
- Respects Rails conventions
- Easy to understand and debug

### 3. Two Middleware
Why two middleware instead of one?
- `RescuedExceptionInterceptor` runs early to catch exceptions before rescue
- `CaptureExceptions` runs late to report after Rails processing
- This ensures we catch both rescued and unrescued exceptions

### 4. Module Prepend for ActiveJob
Using `prepend` instead of `alias_method_chain`:
- Cleaner Ruby pattern
- Respects method resolution order
- Works with other gems that extend ActiveJob
- More maintainable

### 5. Railtie for Integration
Railtie is the Rails-native way to integrate:
- Automatic discovery (no manual setup)
- Access to Rails lifecycle hooks
- Proper initialization order
- Follows Rails conventions

### 6. InitConfig Wrapper
The `InitConfig` class wraps both core and Rails options:
- Single configuration block
- Type-safe option setting
- Clear separation of concerns
- Easy to extend

### 7. Sensitive Data Filtering
Built-in filtering for security:
- Common sensitive parameter names
- Parameter value truncation
- Safe serialization fallbacks
- Fails gracefully if filtering errors

## Testing Strategy

To test this gem, you would:

1. **Unit tests** for each component
   - Configuration options
   - Exception filtering
   - User extraction
   - Parameter sanitization

2. **Integration tests** with Rails
   - Middleware insertion
   - Exception capture flow
   - ActiveJob instrumentation
   - Rails 7.0+ error reporter

3. **Test Rails app**
   - Dummy Rails app in spec/
   - Test actual exception capture
   - Verify user context
   - Test feature flags

## Comparison with Sentry

| Feature | PostHog Rails | Sentry Rails |
|---------|---------------|--------------|
| Separate gem | ✅ | ✅ |
| Middleware-based | ✅ | ✅ |
| ActiveJob | ✅ | ✅ |
| Railtie | ✅ | ✅ |
| Rails 7 errors | ✅ | ✅ |
| Performance tracing | ❌ | ✅ |
| Breadcrumbs | ❌ | ✅ |
| ActionCable | ❌ | ✅ |

## Future Enhancements

Possible additions:
1. **Performance tracing** - Track request/query times
2. **Breadcrumbs** - Capture logs leading up to errors
3. **ActionCable** - WebSocket exception tracking
4. **Background workers** - Sidekiq, Resque integrations
5. **Tests** - Full test suite
6. **Rails generators** - `rails generate posthog:install`
7. **Controller helpers** - `posthog_identify`, `posthog_capture` helpers

## File Sizes

Approximate lines of code:
- `railtie.rb`: ~200 lines
- `capture_exceptions.rb`: ~130 lines
- `configuration.rb`: ~60 lines
- `active_job.rb`: ~80 lines
- `error_subscriber.rb`: ~30 lines
- `rescued_exception_interceptor.rb`: ~25 lines

Total: ~525 lines of implementation code

## Dependencies

Runtime:
- `posthog-ruby` (core SDK)
- `railties >= 5.2.0`

Development (inherited from posthog-ruby):
- `rspec`
- `rubocop`

## Compatibility

- **Ruby**: 3.0+
- **Rails**: 5.2+
- **Tested on**: Rails 5.2, 6.0, 6.1, 7.0, 7.1 (planned)

## Deployment

To release:
```bash
cd posthog-rails
gem build posthog-rails.gemspec
gem push posthog-rails-3.3.3.gem
```

Users install with:
```ruby
gem 'posthog-rails'
```

This automatically brings in `posthog-ruby` as a dependency.
