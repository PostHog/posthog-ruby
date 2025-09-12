# frozen_string_literal: true

require 'posthog/version'
require 'posthog/defaults'
require 'posthog/utils'
require 'posthog/exception_formatter'
require 'posthog/field_parser'
require 'posthog/client'
require 'posthog/send_worker'
require 'posthog/transport'
require 'posthog/response'
require 'posthog/logging'
require 'posthog/exception_capture'
require 'posthog/configuration'

# Automatic exception capture components  
begin
  require 'posthog/rack/middleware'
rescue LoadError
  # Rack not available, skip middleware
end

# Framework integrations
require 'posthog/rails/railtie' if defined?(Rails::Railtie)
require 'posthog/rails/controller_helpers' if defined?(Rails)

# Background job integrations
require 'posthog/integrations/sidekiq' if defined?(Sidekiq)
require 'posthog/integrations/delayed_job' if defined?(Delayed)
