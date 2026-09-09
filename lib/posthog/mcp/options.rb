# frozen_string_literal: true

module PostHog
  module MCP
    # Description override for the injected `context` argument.
    #
    # @!attribute description
    #   @return [String, nil]
    ContextOptions = Struct.new(:description, keyword_init: true)

    # Description override for the injected `llm_model` argument.
    #
    # @!attribute description
    #   @return [String, nil]
    ModelOptions = Struct.new(:description, keyword_init: true)

    # Resolved identity for a session. `distinct_id` becomes the event's
    # distinct id, `properties` go to `$set`, `groups` (`{group_type => group_key}`)
    # are stamped on every event as `$groups`.
    UserIdentity = Struct.new(:distinct_id, :properties, :groups, keyword_init: true) do
      # @api private
      def self.coerce(value)
        case value
        when UserIdentity then value
        when Hash
          distinct_id = value[:distinct_id] || value['distinct_id'] || value[:distinctId] || value['distinctId']
          return nil if distinct_id.nil? || distinct_id.to_s.empty?

          new(
            distinct_id: distinct_id.to_s,
            properties: value[:properties] || value['properties'],
            groups: value[:groups] || value['groups']
          )
        end
      end
    end

    # Result of {PostHog::MCP::Client#prepare_tool_call}: the intent pulled off
    # the call, the arguments with the injected `context` stripped, and whether
    # the call targeted the `get_more_tools` virtual tool.
    PreparedToolCall = Struct.new(:args, :intent, :intent_source, :is_missing_capability, keyword_init: true)

    # Configuration for {PostHog::MCP.instrument}. Mirrors the JS/Python options.
    #
    # @note Experimental: option names may change in a future minor release.
    class Options
      # @return [#call, nil] STDIO-safe log sink receiving single String messages. Default: no-op.
      attr_reader :logger
      # @return [Boolean] Register the `get_more_tools` virtual tool. Default false.
      attr_reader :report_missing
      # @return [String] Name of the virtual tool. Default `get_more_tools`.
      attr_reader :missing_capability_tool_name
      # @return [Boolean] Inject `conversation_id` and anchor `$session_id` on it. Default false.
      attr_reader :enable_conversation_id
      # @return [Boolean] Emit a sibling `$exception` event for failed calls. Default true.
      attr_reader :enable_exception_autocapture
      # @return [Boolean, ContextOptions] Inject the required `context` argument. Default true.
      attr_reader :context
      # @return [Boolean, ModelOptions] Capture `$mcp_llm_model`. Default false.
      attr_reader :capture_model
      # @return [#call, UserIdentity, Hash, nil] `(request, extra) -> UserIdentity | Hash | nil`, or a static identity.
      attr_reader :identify
      # @return [#call, nil] `(request, extra) -> String | nil`, consulted when no `context` arg was passed.
      attr_reader :intent_fallback
      # @return [#call, nil] `(payload) -> payload | nil`; runs once per emitted payload, nil drops it.
      attr_reader :before_send
      # @return [#call, nil] `(request, extra) -> Hash | nil`, spread flat onto every auto-captured event.
      attr_reader :event_properties

      def initialize(logger: nil, report_missing: false, missing_capability_tool_name: nil,
                     enable_conversation_id: false, enable_exception_autocapture: true, context: true,
                     capture_model: false, identify: nil, intent_fallback: nil, before_send: nil,
                     event_properties: nil)
        @logger = logger
        @report_missing = report_missing == true
        @missing_capability_tool_name = missing_capability_tool_name
        @enable_conversation_id = enable_conversation_id == true
        @enable_exception_autocapture = enable_exception_autocapture != false
        @context = normalize_context(context)
        @capture_model = normalize_model(capture_model)
        @identify = identify
        @intent_fallback = intent_fallback
        @before_send = before_send
        @event_properties = event_properties
      end

      # @return [Boolean]
      def context_enabled?
        @context != false
      end

      # @return [String, nil]
      def context_description
        @context.is_a?(ContextOptions) ? @context.description : nil
      end

      # @return [Boolean]
      def capture_model_enabled?
        @capture_model != false
      end

      # @return [String, nil]
      def model_description
        @capture_model.is_a?(ModelOptions) ? @capture_model.description : nil
      end

      private

      def normalize_context(context)
        case context
        when false, nil then context.nil?
        when Hash then ContextOptions.new(description: context[:description] || context['description'])
        else context
        end
      end

      def normalize_model(capture_model)
        case capture_model
        when Hash then ModelOptions.new(description: capture_model[:description] || capture_model['description'])
        when true, ModelOptions then capture_model
        else false
        end
      end
    end
  end
end
