# frozen_string_literal: true

require 'posthog/rails/version'
require 'posthog/rails/delivery_errors'
require 'posthog/rails/mail_mapper'

module PostHog
  module Rails
    # The `:posthog` Action Mailer delivery method. It sends each mail as one PostHog email, through the client that
    # `PostHog.init` made, and sets the mail's `message_id` to PostHog's message ID.
    #
    # A mail's `X-PostHog-Capture-Engagement` header, `true` or `false`, decides whether PostHog captures the email's
    # engagement events (sent, delivered, opened, clicked, bounced) as events on the recipient's person. It defaults to
    # `true`. Turning it off doesn't change the email: PostHog still adds its open pixel to count opens. It never
    # rewrites the email's links, so it counts no clicks.
    #
    # @example config/environments/production.rb
    #   config.action_mailer.delivery_method = :posthog
    #   config.action_mailer.posthog_settings = { default_template_key: 'transactional' }
    class DeliveryMethod
      INTEGRATION = "#{MailMapper::INTEGRATION_NAME}/#{VERSION}".freeze
      private_constant :INTEGRATION

      # @return [Hash] `config.action_mailer.posthog_settings`.
      attr_accessor :settings

      # @param settings [Hash] `default_template_key:` names mail that has no mailer name and sets no
      #   X-PostHog-Template-Key.
      def initialize(settings = {})
        @settings = settings
      end

      # @param mail [Mail::Message]
      # @return [PostHog::Emails::SendResult]
      # @raise [UnsupportedMailError] PostHog can't send part of the mail, so nothing was sent.
      # @raise [DeliveryError] PostHog did not queue the mail.
      def deliver!(mail)
        arguments = MailMapper.new(default_template_key: settings[:default_template_key])
                              .map(mail, derived_template_key: MailerExtensions.template_key(mail))
        result = PostHog.emails.send(**arguments, integration: INTEGRATION)
        mail.message_id = result.id
        result
      rescue PostHog::EmailError => e
        raise DeliveryError, e
      end
    end

    # Names each mail an Action Mailer mailer builds `<mailer>-<action>`, such as `user_mailer-welcome`, so PostHog
    # groups its sends.
    #
    # @api private
    module MailerExtensions
      TEMPLATE_KEY = :@posthog_template_key
      private_constant :TEMPLATE_KEY

      # @param mail [Mail::Message]
      # @return [String, nil]
      def self.template_key(mail)
        mail.instance_variable_get(TEMPLATE_KEY) if mail.instance_variable_defined?(TEMPLATE_KEY)
      end

      # @api private
      def mail(...)
        super.tap { |message| message.instance_variable_set(TEMPLATE_KEY, "#{mailer_name}-#{action_name}") }
      end
    end
  end
end
