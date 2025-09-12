# frozen_string_literal: true

if defined?(Rails::Railtie)
  module PostHog
    module Rails
      class Railtie < ::Rails::Railtie
        config.posthog = ActiveSupport::OrderedOptions.new

        # Initialize PostHog configuration from Rails config
        initializer 'posthog.configure', before: :load_config_initializers do |app|
          PostHog.configure do |config|
            # Load from Rails configuration
            if app.config.posthog.api_key
              config.api_key = app.config.posthog.api_key
            end

            if app.config.posthog.host
              config.host = app.config.posthog.host
            end

            if app.config.posthog.personal_api_key
              config.personal_api_key = app.config.posthog.personal_api_key
            end

            # Auto-capture defaults to true in Rails unless explicitly set
            unless app.config.posthog.key?(:auto_capture_exceptions)
              config.auto_capture_exceptions = true
            else
              config.auto_capture_exceptions = app.config.posthog.auto_capture_exceptions
            end

            if app.config.posthog.ignored_exceptions
              config.ignored_exceptions = app.config.posthog.ignored_exceptions
            end

            # Environment-specific defaults
            case ::Rails.env
            when 'test'
              config.test_mode = true
              config.auto_capture_exceptions = false unless app.config.posthog.key?(:auto_capture_exceptions)
            when 'development'
              config.auto_capture_exceptions = false unless app.config.posthog.key?(:auto_capture_exceptions)
            end

            # Rails-specific ignored exceptions
            config.ignored_exceptions += rails_specific_ignored_exceptions
          end
        end

        # Add middleware after Rails exception handling middleware
        initializer 'posthog.middleware' do |app|
          # Insert after ShowExceptions but before other exception handlers
          # This ensures we catch exceptions that Rails would normally handle
          app.middleware.insert_after ActionDispatch::ShowExceptions, PostHog::Rack::Middleware
        end

        # Set up Rails-specific exception handling
        initializer 'posthog.exception_handling' do |app|
          if PostHog.configuration.auto_capture_exceptions
            # Hook into Rails' exception handling
            ActiveSupport::Notifications.subscribe 'process_action.action_controller' do |*args|
              event = ActiveSupport::Notifications::Event.new(*args)
              
              if event.payload[:exception_object]
                exception = event.payload[:exception_object]
                controller = event.payload[:controller]
                action = event.payload[:action]
                
                # Extract user context from controller
                distinct_id = extract_distinct_id_from_controller(controller) rescue 'anonymous'
                
                PostHog.capture_exception(exception, {
                  distinct_id: distinct_id,
                  tags: {
                    source: 'rails_controller',
                    controller: controller,
                    action: action,
                    environment: ::Rails.env
                  },
                  extra: {
                    params: filter_sensitive_params(event.payload[:params]),
                    view_runtime: event.payload[:view_runtime],
                    db_runtime: event.payload[:db_runtime]
                  },
                  handled: false
                })
              end
            end
          end
        end

        # Set up ActionMailer exception handling
        initializer 'posthog.action_mailer' do |app|
          if PostHog.configuration.auto_capture_exceptions && defined?(ActionMailer)
            ActiveSupport::Notifications.subscribe /deliver\.action_mailer/ do |*args|
              event = ActiveSupport::Notifications::Event.new(*args)
              
              if event.payload[:exception_object]
                exception = event.payload[:exception_object]
                
                PostHog.capture_exception(exception, {
                  distinct_id: 'system',
                  tags: {
                    source: 'action_mailer',
                    mailer: event.payload[:mailer],
                    action: event.payload[:action],
                    environment: ::Rails.env
                  },
                  extra: {
                    args: event.payload[:args]
                  },
                  handled: false
                })
              end
            end
          end
        end

        # Set up ActiveJob exception handling
        initializer 'posthog.active_job' do |app|
          if PostHog.configuration.auto_capture_exceptions && defined?(ActiveJob)
            ActiveSupport::Notifications.subscribe 'perform.active_job' do |*args|
              event = ActiveSupport::Notifications::Event.new(*args)
              
              if event.payload[:exception_object]
                exception = event.payload[:exception_object]
                job = event.payload[:job]
                
                PostHog.capture_exception(exception, {
                  distinct_id: job.arguments.first&.respond_to?(:id) ? job.arguments.first.id.to_s : 'system',
                  tags: {
                    source: 'active_job',
                    job_class: job.class.name,
                    queue_name: job.queue_name,
                    environment: ::Rails.env
                  },
                  extra: {
                    arguments: job.arguments,
                    job_id: job.job_id,
                    enqueued_at: job.enqueued_at,
                    executions: job.executions
                  },
                  handled: false
                })
              end
            end
          end
        end

        # Add PostHog helpers to controllers
        initializer 'posthog.controller_helpers' do
          ActiveSupport.on_load(:action_controller) do
            include PostHog::Rails::ControllerHelpers
          end
        end

        private

        def self.rails_specific_ignored_exceptions
          [
            'ActionView::MissingTemplate',
            'ActionController::UnknownFormat', 
            'ActionController::InvalidAuthenticityToken',
            'ActionDispatch::Http::MimeNegotiation::InvalidType',
            'ActionController::ParameterMissing',
            'ActionController::UnpermittedParameters',
            'ActiveRecord::RecordNotFound',
            'ActiveRecord::RecordInvalid',
            'ActiveRecord::RecordNotSaved',
            'ActiveRecord::RecordNotDestroyed'
          ]
        end

        def self.extract_distinct_id_from_controller(controller_class)
          return 'anonymous' unless defined?(controller_class)
          
          # This is a bit tricky since we only have the controller class name
          # In a real implementation, we'd need access to the controller instance
          # For now, return a placeholder that indicates we need controller instance access
          "#{controller_class.name.underscore}_user"
        end

        def self.filter_sensitive_params(params)
          return {} unless params
          
          # Rails parameter filtering
          if defined?(::Rails.application) && ::Rails.application.config.filter_parameters
            filter = ActionDispatch::Http::ParameterFilter.new(::Rails.application.config.filter_parameters)
            filter.filter(params)
          else
            # Basic filtering if Rails parameter filtering not available
            sensitive_keys = %w[password token secret key api_key access_token]
            filtered_params = params.dup
            
            filtered_params.each do |key, value|
              if sensitive_keys.any? { |sensitive| key.to_s.downcase.include?(sensitive) }
                filtered_params[key] = '[FILTERED]'
              end
            end
            
            filtered_params
          end
        rescue StandardError => e
          { error: "Failed to filter params: #{e.message}" }
        end
      end
    end
  end
end