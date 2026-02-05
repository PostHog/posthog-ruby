# frozen_string_literal: true

unless defined?(Rails)
  raise LoadError, 'posthog-rails requires Rails. Use the posthog-ruby gem directly for non-Rails applications.'
end

# Load core PostHog Ruby SDK
require 'posthog'

# Load Rails integration
require 'posthog/rails'
