# frozen_string_literal: true

# PostHog Rails Initializer
# Place this file in config/initializers/posthog.rb

PostHog.init do |config|
  # ============================================================================
  # REQUIRED CONFIGURATION
  # ============================================================================

  # Your PostHog project API key (required)
  # Get this from: PostHog Project Settings > API Keys
  # https://app.posthog.com/settings/project-details#variables
  config.api_key = ENV.fetch('POSTHOG_API_KEY', nil)

  # ============================================================================
  # CORE POSTHOG CONFIGURATION
  # ============================================================================

  # For PostHog Cloud, use: https://us.i.posthog.com or https://eu.i.posthog.com
  config.host = ENV.fetch('POSTHOG_HOST', 'https://us.i.posthog.com')

  # Personal API key (optional, but required for local feature flag evaluation)
  # Get this from: PostHog Settings > Personal API Keys
  # https://app.posthog.com/settings/user-api-keys
  config.personal_api_key = ENV.fetch('POSTHOG_PERSONAL_API_KEY', nil)

  # Maximum number of events to queue before dropping (default: 10000)
  config.max_queue_size = 10_000

  # Feature flags polling interval in seconds (default: 30)
  config.feature_flags_polling_interval = 30

  # Feature flag request timeout in seconds (default: 3)
  config.feature_flag_request_timeout_seconds = 3

  # Error callback - called when PostHog encounters an error
  config.on_error = proc { |status, message|
    Rails.logger.error("[PostHog] Error #{status}: #{message}")
  }

  # Before send callback - modify or filter events before sending
  # Return nil to prevent the event from being sent
  # config.before_send = proc { |event|
  #   # Filter out test users
  #   return nil if event[:properties]&.dig('$user_email')&.end_with?('@test.com')
  #
  #   # Add custom properties to all events
  #   event[:properties] ||= {}
  #   event[:properties]['environment'] = Rails.env
  #
  #   event
  # }

  # ============================================================================
  # RAILS-SPECIFIC CONFIGURATION
  # ============================================================================

  # Automatically capture exceptions (default: true)
  config.auto_capture_exceptions = true

  # Report exceptions that Rails rescues (e.g., with rescue_from) (default: true)
  config.report_rescued_exceptions = true

  # Automatically instrument ActiveJob background jobs (default: true)
  config.auto_instrument_active_job = true

  # Capture user context with exceptions (default: true)
  config.capture_user_context = true

  # Controller method name to get current user (default: :current_user)
  # Change this if your app uses a different method name
  config.current_user_method = :current_user

  # Additional exception classes to exclude from reporting
  # These are added to the default excluded exceptions
  config.excluded_exceptions = [
    # 'MyCustom404Error',
    # 'MyCustomValidationError'
  ]

  # ============================================================================
  # ENVIRONMENT-SPECIFIC CONFIGURATION
  # ============================================================================

  # Disable in test environment
  config.test_mode = true if Rails.env.test?

  # Optional: Disable in development
  # config.test_mode = true if Rails.env.test? || Rails.env.development?
end

# ============================================================================
# DEFAULT EXCLUDED EXCEPTIONS
# ============================================================================
# The following exceptions are excluded by default:
#
# - AbstractController::ActionNotFound
# - ActionController::BadRequest
# - ActionController::InvalidAuthenticityToken
# - ActionController::InvalidCrossOriginRequest
# - ActionController::MethodNotAllowed
# - ActionController::NotImplemented
# - ActionController::ParameterMissing
# - ActionController::RoutingError
# - ActionController::UnknownFormat
# - ActionController::UnknownHttpMethod
# - ActionDispatch::Http::Parameters::ParseError
# - ActiveRecord::RecordNotFound
# - ActiveRecord::RecordNotUnique
#
# These can be re-enabled by removing them from the exclusion list if needed.

# ============================================================================
# USAGE EXAMPLES
# ============================================================================

# Track custom events:
# PostHog.capture(
#   distinct_id: current_user.id,
#   event: 'user_signed_up',
#   properties: {
#     plan: 'pro',
#     source: 'organic'
#   }
# )

# Identify users:
# PostHog.identify(
#   distinct_id: current_user.id,
#   properties: {
#     email: current_user.email,
#     name: current_user.name,
#     plan: current_user.plan
#   }
# )

# Check feature flags:
# if PostHog.is_feature_enabled('new-checkout-flow', current_user.id)
#   render 'checkout/new'
# else
#   render 'checkout/old'
# end

# Capture exceptions manually:
# begin
#   dangerous_operation
# rescue => e
#   PostHog.capture_exception(e, current_user.id, { context: 'manual' })
#   raise
# end
