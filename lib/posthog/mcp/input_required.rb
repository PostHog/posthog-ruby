# frozen_string_literal: true

module PostHog
  module MCP
    # Reads an `input_required` round: the result a tool returns to ask the
    # client for more input, such as a confirmation, before it runs.
    #
    # @api private
    module InputRequired
      RESULT_TYPE = 'input_required'
      # `$mcp_input_request_methods` holds at most this many entries.
      MAX_METHODS = 100

      module_function

      # The method of each request in the round, ordered by request key, or nil
      # when `result` is not a round. A round that carries only `requestState`
      # has none.
      #
      # @return [Array<String>, nil]
      def request_methods(result)
        result = result.to_h if round_object?(result)
        return nil unless result.is_a?(Hash) && value(result, :resultType) == RESULT_TYPE

        requests = value(result, :inputRequests)
        return [] unless requests.is_a?(Hash)

        ordered = requests.sort_by { |key, _| key.to_s }.map { |_, request| request }
        bound(ordered.map { |request| request.is_a?(Hash) ? value(request, :method) : nil })
      end

      # Keeps the string methods, up to the property's entry limit.
      #
      # @return [Array<String>]
      def bound(methods)
        (methods.is_a?(Array) ? methods : []).grep(String).first(MAX_METHODS)
      end

      def round_object?(result)
        defined?(::MCP::Server::InputRequiredResult) && result.is_a?(::MCP::Server::InputRequiredResult)
      end

      def value(hash, key)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end
  end
end
