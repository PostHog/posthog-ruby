# frozen_string_literal: true

module PostHog
  module MCP
    # Resolve `$mcp_intent` from the agent-supplied `context` argument (source
    # `context_parameter`) or the customer's `intent_fallback` (source `inferred`).
    #
    # @api private
    module Intent
      module_function

      def context_argument(request)
        params = request[:params] || request['params'] || {}
        arguments = (params[:arguments] || params['arguments']) || {}
        return nil unless arguments.is_a?(Hash)

        context = arguments[:context] || arguments['context']
        context.is_a?(String) && !context.strip.empty? ? context : nil
      end

      def normalize(intent)
        return nil unless intent.is_a?(String)

        trimmed = intent.strip
        trimmed.empty? ? nil : trimmed
      end

      # @return [Array(String, String), nil] `[intent, source]`
      def resolve(data, request, extra)
        params = request[:params] || request['params'] || {}
        name = params[:name] || params['name']
        missing_name = Tools.missing_capability_tool_name(data.options)
        context = context_argument(request)
        return [context, 'context_parameter'] if data.options.context_enabled? && name != missing_name && context

        run_fallback(data, request, extra)
      end

      def run_fallback(data, request, extra)
        fallback = data.options.intent_fallback
        return nil unless fallback

        intent = normalize(Callbacks.call(fallback, request, extra))
        intent ? [intent, 'inferred'] : nil
      rescue StandardError => e
        Log.debug(data.options, "intent_fallback callback error: #{e.message}")
        nil
      end
    end

    # Model capture (`capture_model`). MCP does not standardize model identity:
    # some clients expose it through vendor metadata, others let the agent
    # self-report through the injected `llm_model` argument. Client metadata wins;
    # `$mcp_llm_model_source` preserves provenance. Both are unverified.
    #
    # @api private
    module ModelCapture
      PARAM_NAME = 'llm_model'
      CODEX_TURN_METADATA_KEY = 'x-codex-turn-metadata'

      module_function

      def normalize(model)
        return nil unless model.is_a?(String)

        trimmed = model.strip
        trimmed.empty? || trimmed.casecmp('unknown').zero? ? nil : trimmed
      end

      # @param request [Hash] JSON-RPC-shaped request (params may carry `_meta`)
      # @param self_reported [String, nil] the stripped `llm_model` argument, if the SDK owned it
      # @return [Array(String, String), nil] `[model, source]`
      def resolve(request, self_reported)
        params = request[:params] || request['params'] || {}
        meta = params[:_meta] || params['_meta']
        codex = meta.is_a?(Hash) ? (meta[CODEX_TURN_METADATA_KEY] || meta[CODEX_TURN_METADATA_KEY.to_sym]) : nil
        if codex.is_a?(Hash)
          model = normalize(codex['model'] || codex[:model])
          return [model, 'client_metadata'] if model
        end

        model = normalize(self_reported)
        model ? [model, 'self_reported'] : nil
      end
    end

    # Raw transport headers stamped per event (HTTP only, never cached).
    #
    # @api private
    module TransportIdentity
      CLIENT_USER_AGENT_HEADER = 'user-agent'
      VENDOR_CLIENT_HEADER = 'x-anthropic-client'

      module_function

      def stamp(event, headers)
        return event unless headers.is_a?(Hash)

        user_agent = headers[CLIENT_USER_AGENT_HEADER]
        vendor = headers[VENDOR_CLIENT_HEADER]
        event['client_user_agent'] = user_agent if user_agent.is_a?(String) && !user_agent.empty?
        event['vendor_client'] = vendor if vendor.is_a?(String) && !vendor.empty?
        event
      end
    end
  end
end
