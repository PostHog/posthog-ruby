# frozen_string_literal: true

require 'posthog/exception_capture'

module PostHog
  module MCP
    # Builds PostHog error-tracking properties (`$exception_list` /
    # `$exception_level`) from anything a tool can fail with, reusing
    # {PostHog::ExceptionCapture} so MCP failures group like every other
    # exception the Ruby SDK reports.
    #
    # @api private
    module Exceptions
      GENERIC_MECHANISM = { 'type' => 'generic', 'handled' => true }.freeze

      # Messages the Ruby `mcp` gem wraps around whatever a tool raised.
      DISPATCH_WRAPPER_TYPE = 'MCP::Server::RequestHandlerError'
      DISPATCH_WRAPPER_PREFIXES = ['Internal error calling tool', 'Internal error handling'].freeze

      module_function

      # @param error [Exception, String, Hash, Object] exception, message, or an
      #   `isError` tool result (`{content: [...], isError: true}`)
      # @return [Hash] `{'$exception_list' => [...], '$exception_level' => 'error'}`
      def capture_exception(error)
        return from_message(call_tool_result_message(error)) if call_tool_result?(error)
        return from_exception(error) if error.is_a?(Exception)
        return from_message(error) if error.is_a?(String)

        from_message(safe_to_s(error))
      end

      def from_exception(error)
        list = PostHog::ExceptionCapture.build_exception_list(error) || []
        original = error.respond_to?(:original_error) ? error.original_error : nil
        if original.is_a?(Exception) && !chain_includes?(error, original)
          list.concat(PostHog::ExceptionCapture.build_exception_list(original) || [])
        end
        list = [message_entry(error.class.to_s, error.message.to_s)] if list.empty?
        { '$exception_list' => list, '$exception_level' => 'error' }
      end

      def from_message(message)
        { '$exception_list' => [message_entry('Error', message)], '$exception_level' => 'error' }
      end

      def message_entry(type, message)
        { 'mechanism' => GENERIC_MECHANISM.dup, 'type' => type, 'value' => message }
      end

      # Whether an `$exception_list` entry is the gem's dispatch wrapper, whose
      # message says nothing the tool name does not already say.
      def dispatch_wrapper?(entry)
        return false unless entry.is_a?(Hash)

        value = entry['value'].to_s
        entry['type'] == DISPATCH_WRAPPER_TYPE && DISPATCH_WRAPPER_PREFIXES.any? { |p| value.start_with?(p) }
      end

      # The `$exception_list` entry carrying the actual failure reason, stepping
      # past consecutive dispatch wrappers.
      def primary_exception(error)
        return {} unless error.is_a?(Hash)

        list = error['$exception_list']
        return {} unless list.is_a?(Array) && !list.empty?

        index = 0
        index += 1 while index + 1 < list.length && list[index + 1].is_a?(Hash) && dispatch_wrapper?(list[index])
        list[index].is_a?(Hash) ? list[index] : {}
      end

      def call_tool_result?(value)
        return false unless value.is_a?(Hash)

        content = value['content'] || value[:content]
        (value.key?('isError') || value.key?(:isError)) && content.is_a?(Array)
      end

      def call_tool_result_message(result)
        content = result['content'] || result[:content] || []
        texts = content.filter_map do |part|
          next unless part.is_a?(Hash)

          type = part['type'] || part[:type]
          text = part['text'] || part[:text]
          text if type == 'text' && text.is_a?(String)
        end
        joined = texts.join(' ').strip
        joined.empty? ? 'Unknown error' : joined
      end

      def chain_includes?(error, target)
        current = error.cause
        seen = {}.compare_by_identity
        while current && !seen.key?(current)
          return true if current.equal?(target)

          seen[current] = true
          current = current.cause
        end
        false
      end

      def safe_to_s(value)
        value.to_s
      rescue StandardError
        'Unknown error'
      end
    end
  end
end
