# frozen_string_literal: true

# Load core PostHog Ruby SDK
require 'posthog'

# Load Rails integration
require 'posthog/rails' if defined?(Rails)
