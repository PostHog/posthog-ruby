# frozen_string_literal: true

module PostHog
  module MCP
    # Logging for the MCP integration.
    #
    # Debug-level chatter goes only to the `logger:` option (a no-op by default),
    # because a stdio MCP server owns `$stdout` for the protocol and the core
    # SDK's default logger writes there. Warnings additionally reach the app's
    # logger when Rails is loaded (where {PostHog::Logging.logger} wraps
    # `Rails.logger`) and stderr otherwise, so misconfiguration is never silent
    # and never corrupts a stdio transport.
    #
    # @api private
    module Log
      module_function

      def debug(options, message)
        sink = options.respond_to?(:logger) ? options.logger : nil
        sink&.call(message)
      rescue StandardError
        nil
      end

      def warn(options, message)
        debug(options, message)
        if defined?(::Rails)
          PostHog::Logging.logger.warn(message)
        else
          Kernel.warn("[posthog-ruby] #{message}")
        end
      rescue StandardError
        nil
      end
    end
  end
end
