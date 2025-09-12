# frozen_string_literal: true

module PostHog
  module Rails
    module ControllerHelpers
      extend ActiveSupport::Concern

      # Get PostHog distinct ID for the current user/session
      def posthog_distinct_id
        @posthog_distinct_id ||= begin
          # 1. Try current_user if available
          if respond_to?(:current_user, true) && current_user
            current_user.id.to_s
          # 2. Try user_signed_in? for Devise
          elsif respond_to?(:user_signed_in?, true) && user_signed_in? && respond_to?(:current_user, true)
            current_user.id.to_s
          # 3. Check session for stored user ID
          elsif session[:user_id]
            session[:user_id].to_s
          # 4. Check cookies for PostHog user ID
          elsif cookies.signed[:posthog_user_id]
            cookies.signed[:posthog_user_id]
          # 5. Generate and store anonymous ID
          else
            anonymous_id = SecureRandom.uuid
            cookies.signed[:posthog_user_id] = {
              value: anonymous_id,
              expires: 1.year.from_now,
              httponly: true
            }
            anonymous_id
          end
        end
      end

      # Capture an exception with Rails context
      def posthog_capture_exception(exception, extra_attrs = {})
        return unless PostHog.configured?

        attrs = {
          distinct_id: posthog_distinct_id,
          tags: {
            source: 'rails_controller',
            controller: controller_name,
            action: action_name,
            environment: ::Rails.env.to_s
          },
          extra: {
            request_id: request.request_id,
            url: request.url,
            method: request.method,
            user_agent: request.user_agent,
            remote_ip: request.remote_ip,
            params: filter_params_for_posthog(params.to_unsafe_h)
          }
        }.deep_merge(extra_attrs)

        PostHog.capture_exception(exception, attrs)
      end

      # Capture an event with Rails context
      def posthog_capture(event_name, properties = {})
        return unless PostHog.configured?

        PostHog.capture({
          distinct_id: posthog_distinct_id,
          event: event_name,
          properties: {
            controller: controller_name,
            action: action_name,
            environment: ::Rails.env.to_s
          }.merge(properties)
        })
      end

      # Identify the current user
      def posthog_identify(properties = {})
        return unless PostHog.configured?

        user_properties = {}
        
        # Try to extract user properties if current_user is available
        if respond_to?(:current_user, true) && current_user
          user_properties = extract_user_properties(current_user)
        end

        PostHog.identify({
          distinct_id: posthog_distinct_id,
          properties: user_properties.merge(properties)
        })
      end

      private

      def filter_params_for_posthog(params)
        return {} unless params

        # Use Rails parameter filtering if available
        if ::Rails.application.config.filter_parameters.any?
          filter = ActionDispatch::Http::ParameterFilter.new(::Rails.application.config.filter_parameters)
          filter.filter(params)
        else
          # Basic filtering
          sensitive_keys = %w[password password_confirmation token secret key api_key access_token]
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

      def extract_user_properties(user)
        properties = {}

        # Common user attributes
        %w[id email name first_name last_name username].each do |attr|
          if user.respond_to?(attr)
            value = user.public_send(attr)
            properties[attr] = value if value.present?
          end
        end

        # Created at timestamp
        if user.respond_to?(:created_at) && user.created_at
          properties[:created_at] = user.created_at.iso8601
        end

        # User type or role if available
        if user.respond_to?(:role)
          properties[:role] = user.role
        elsif user.respond_to?(:user_type)
          properties[:user_type] = user.user_type
        end

        properties
      rescue StandardError => e
        { error: "Failed to extract user properties: #{e.message}" }
      end
    end
  end
end