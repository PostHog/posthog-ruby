# frozen_string_literal: true

require 'posthog/rails/version'
require 'posthog/rails/delivery_errors'
require 'posthog/rails/mail_mapper'

module PostHog
  module Rails
    # The `:posthog` Action Mailer delivery method. It sends each mail as one PostHog email, through the client that
    # `PostHog.init` made, and sets the mail's `message_id` to PostHog's message ID.
    #
    # A mail's reserved headers set the send's options, and are never sent. Each of these takes `true` or `false`, and
    # PostHog decides when the mail leaves it out:
    # - `X-PostHog-Track-Opens`: whether PostHog adds its open pixel to count opens;
    # - `X-PostHog-Track-Clicks`: whether PostHog rewrites the links to count clicks. Off by default for a sensitive
    #   mail, and it needs open tracking;
    # - `X-PostHog-Capture-Engagement`: whether PostHog captures the email's engagement events (sent, delivered,
    #   opened, clicked, bounced) as events on the recipient's person;
    # - `X-PostHog-Sensitive`: `true` for mail with login links, reset tokens or codes. PostHog leaves its links
    #   unchanged unless `X-PostHog-Track-Clicks` is `true`, its subject off engagement events, and its content out of
    #   logs. Left out, PostHog takes the setting of the template whose key matches, and treats the mail as sensitive
    #   when none matches.
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
        result = send_email(mail)
        mail.message_id = result.id
        result
      rescue UnsupportedMailError, DeliveryError => e
        # Mail's deliver drops the error when the mailer turns raise_delivery_errors off; this line keeps a trace of it.
        PostHog::Logging.logger.error("PostHog did not send an email: #{e.message}") unless mail.raise_delivery_errors
        raise
      end

      private

      def send_email(mail)
        arguments = MailMapper.new(default_template_key: settings[:default_template_key])
                              .map(mail, derived_template_key: MailerExtensions.template_key(mail))
        begin
          PostHog.emails.send(**arguments, integration: INTEGRATION)
        rescue ArgumentError => e
          # The SDK checks its arguments before any request, such as the subject a send needs.
          raise UnsupportedMailError.new(refusal: 'invalid_mail', detail: e.message.chomp('.'))
        end
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
