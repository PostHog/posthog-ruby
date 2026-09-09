# frozen_string_literal: true

module PostHog
  module MCP
    # Value of `$mcp_source` on every primary `$mcp_*` event.
    SOURCE = 'posthog_mcp_analytics'

    # `$lib` stamped on MCP analytics events (per event, never on the client).
    LIB_NAME = 'posthog-ruby-mcp'

    # Generated (in-memory) sessions roll over after this much inactivity.
    INACTIVITY_TIMEOUT_MINUTES = 30

    # Header carrying the transport session id, and our self-encoded token.
    MCP_SESSION_HEADER = 'mcp-session-id'

    # Description of the injected `context` argument.
    DEFAULT_CONTEXT_PARAMETER_DESCRIPTION =
      'Explain in 15-25 words, in third person, why this tool is called and how it supports ' \
      "the user's goal. For analytics only. You MUST describe only the abstract purpose of the " \
      'tool call. NEVER include, repeat, paraphrase, or infer personal, sensitive, or identifying ' \
      'information from the user request or tool results, including names, emails, phone numbers, ' \
      'IPs, IDs, or credentials. You MUST generalize specific entities into roles such as "a user", ' \
      '"the customer", or "an account". Example: "Retrieving a customer\'s recent orders to ' \
      'investigate a billing issue and help support determine the appropriate resolution."'

    # Description of the injected `llm_model` argument.
    DEFAULT_MODEL_PARAMETER_DESCRIPTION =
      'The exact model identifier you (the assistant) are running as, taken from your system ' \
      'prompt or environment (e.g. "claude-opus-4-8", "gpt-5.2"). Used for analytics only. If you ' \
      'do not know your model identifier with certainty, pass "unknown" — never guess.'

    # Description of the injected `conversation_id` argument.
    DEFAULT_CONVERSATION_ID_DESCRIPTION =
      "Echo the conversation_id from the server's previous response. The server provides it on " \
      'the first call — never invent one, and do not issue parallel tool calls until you have it.'

    # PostHog-owned event names. All `$`-prefixed per the PostHog convention.
    module Event
      CUSTOM = '$mcp_custom'
      EXCEPTION = '$exception'
      IDENTIFY = '$identify'
      INITIALIZE = '$mcp_initialize'
      MISSING_CAPABILITY = '$mcp_missing_capability'
      PROMPT_GET = '$mcp_prompt_get'
      PROMPTS_LIST = '$mcp_prompts_list'
      RESOURCE_READ = '$mcp_resource_read'
      RESOURCES_LIST = '$mcp_resources_list'
      TOOL_CALL = '$mcp_tool_call'
      TOOLS_LIST = '$mcp_tools_list'
    end

    # PostHog property wire keys emitted on MCP events.
    module Property
      CLIENT_NAME = '$mcp_client_name'
      CLIENT_USER_AGENT = '$mcp_client_user_agent'
      CLIENT_VERSION = '$mcp_client_version'
      VENDOR_CLIENT = '$mcp_vendor_client'
      PROTOCOL_VERSION = '$mcp_protocol_version'
      CONVERSATION_ID = '$mcp_conversation_id'
      DURATION_MS = '$mcp_duration_ms'
      ERROR_MESSAGE = '$mcp_error_message'
      ERROR_TYPE = '$mcp_error_type'
      IS_ERROR = '$mcp_is_error'
      INTENT = '$mcp_intent'
      INTENT_SOURCE = '$mcp_intent_source'
      LISTED_TOOL_NAMES = '$mcp_listed_tool_names'
      LLM_MODEL = '$mcp_llm_model'
      LLM_MODEL_SOURCE = '$mcp_llm_model_source'
      PARAMETERS = '$mcp_parameters'
      RESOURCE_NAME = '$mcp_resource_name'
      RESPONSE = '$mcp_response'
      SERVER_NAME = '$mcp_server_name'
      SERVER_VERSION = '$mcp_server_version'
      SESSION_ID = '$session_id'
      SOURCE = '$mcp_source'
      TOOL_CATEGORY = '$mcp_tool_category'
      TOOL_DESCRIPTION = '$mcp_tool_description'
      TOOL_NAME = '$mcp_tool_name'
    end

    # Internal dispatch keys for the event pipeline (never sent on the wire).
    #
    # @api private
    module EventType
      CUSTOM = 'posthog:custom'
      IDENTIFY = 'posthog:identify'
      MCP_INITIALIZE = 'mcp:initialize'
      MCP_MISSING_CAPABILITY = 'mcp:missing_capability'
      MCP_PROMPTS_GET = 'mcp:prompts/get'
      MCP_PROMPTS_LIST = 'mcp:prompts/list'
      MCP_RESOURCES_LIST = 'mcp:resources/list'
      MCP_RESOURCES_READ = 'mcp:resources/read'
      MCP_TOOLS_CALL = 'mcp:tools/call'
      MCP_TOOLS_LIST = 'mcp:tools/list'

      EVENT_NAME_BY_TYPE = {
        CUSTOM => Event::CUSTOM,
        IDENTIFY => Event::IDENTIFY,
        MCP_INITIALIZE => Event::INITIALIZE,
        MCP_MISSING_CAPABILITY => Event::MISSING_CAPABILITY,
        MCP_PROMPTS_GET => Event::PROMPT_GET,
        MCP_PROMPTS_LIST => Event::PROMPTS_LIST,
        MCP_RESOURCES_LIST => Event::RESOURCES_LIST,
        MCP_RESOURCES_READ => Event::RESOURCE_READ,
        MCP_TOOLS_CALL => Event::TOOL_CALL,
        MCP_TOOLS_LIST => Event::TOOLS_LIST
      }.freeze
    end
  end
end
