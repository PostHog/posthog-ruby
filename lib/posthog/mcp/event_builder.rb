# frozen_string_literal: true

module PostHog
  module MCP
    # Translates a processed internal event (string keys) into one or two
    # PostHog payloads: the main `$mcp_*` event plus an optional `$exception`
    # sibling. Port of the JS/Python `buildPostHogCaptureEvents`.
    #
    # @api private
    module EventBuilder
      P = Property

      module_function

      # @return [Array<Hash>] payloads `{'event', 'distinct_id', 'properties', 'timestamp'}`
      def build(event, enable_exception_autocapture: true)
        batch = [build_capture_event(event)]
        if event['is_error'] && truthy?(event['error']) && enable_exception_autocapture != false
          batch << build_exception_event(event)
        end
        batch
      end

      def distinct_id(event)
        present(event['identify_actor_given_id']) || present(event['session_id']) || 'anonymous'
      end

      def timestamp(event)
        event['timestamp'] || Time.now.utc
      end

      def build_capture_event(event)
        properties = { P::SOURCE => SOURCE }
        add_session_id(event, properties)
        add_conversation_id(event, properties)
        add_person_processing(event, properties)
        add_groups(event, properties)
        add_common_properties(event, properties)
        add_custom_properties(event, properties)

        name = present(event['event_name']) || EventType::EVENT_NAME_BY_TYPE.fetch(event['event_type'], Event::CUSTOM)
        { 'event' => name, 'distinct_id' => distinct_id(event), 'properties' => properties,
          'timestamp' => timestamp(event) }
      end

      def add_session_id(event, properties)
        session_id = event['session_id']
        properties[P::SESSION_ID] = session_id if session_id.is_a?(String) && !session_id.empty?
      end

      def add_conversation_id(event, properties)
        conversation_id = event['conversation_id']
        properties[P::CONVERSATION_ID] = conversation_id unless conversation_id.nil? || conversation_id == ''
      end

      def add_groups(event, properties)
        groups = event['groups']
        properties['$groups'] = groups if truthy?(groups)
      end

      # Without a resolved identity the distinct id is just the session id, so
      # processing a person profile would mint one anonymous person per session.
      def add_person_processing(event, properties)
        properties['$process_person_profile'] = false unless present(event['identify_actor_given_id'])
      end

      def tool_call?(event)
        event['event_type'] == EventType::MCP_TOOLS_CALL
      end

      def add_common_properties(event, properties)
        if present(event['resource_name'])
          properties[P::RESOURCE_NAME] = event['resource_name']
          properties[P::TOOL_NAME] = event['resource_name'] if tool_call?(event)
        end
        if present(event['tool_description']) && tool_call?(event)
          properties[P::TOOL_DESCRIPTION] =
            event['tool_description']
        end
        properties[P::TOOL_CATEGORY] = event['tool_category'] if present(event['tool_category']) && tool_call?(event)
        listed = event['listed_tool_names']
        if listed.is_a?(Array) && !listed.empty? && event['event_type'] == EventType::MCP_TOOLS_LIST
          properties[P::LISTED_TOOL_NAMES] = listed
        end
        properties[P::DURATION_MS] = event['duration'] unless event['duration'].nil?
        properties[P::SERVER_NAME] = event['server_name'] if present(event['server_name'])
        properties[P::SERVER_VERSION] = event['server_version'] if present(event['server_version'])
        properties[P::CLIENT_NAME] = event['client_name'] if present(event['client_name'])
        properties[P::CLIENT_VERSION] = event['client_version'] if present(event['client_version'])
        properties[P::CLIENT_USER_AGENT] = event['client_user_agent'] if present(event['client_user_agent'])
        properties[P::VENDOR_CLIENT] = event['vendor_client'] if present(event['vendor_client'])
        properties[P::PROTOCOL_VERSION] = event['protocol_version'] if present(event['protocol_version'])
        properties[P::INTENT] = event['user_intent'] if present(event['user_intent'])
        properties[P::INTENT_SOURCE] = event['user_intent_source'] if present(event['user_intent_source'])
        properties[P::LLM_MODEL] = event['llm_model'] if present(event['llm_model'])
        properties[P::LLM_MODEL_SOURCE] = event['llm_model_source'] if present(event['llm_model_source'])
        properties[P::IS_ERROR] = event['is_error'] unless event['is_error'].nil?
        add_error_details(event, properties) if event['is_error']
        properties[P::PARAMETERS] = event['parameters'] unless event['parameters'].nil?
        properties[P::RESPONSE] = event['response'] unless event['response'].nil?
        actor_data = event['identify_actor_data']
        properties['$set'] = actor_data.dup if actor_data.is_a?(Hash) && !actor_data.empty?
      end

      # Surface the failure reason on the primary event itself, so dashboards
      # need not join to the `$exception` sibling (which can be switched off).
      def add_error_details(event, properties)
        first = Exceptions.primary_exception(event['error'])
        error_type = present(event['error_type']) || present(first['type'])
        properties[P::ERROR_TYPE] = error_type if error_type
        message = first['value']
        properties[P::ERROR_MESSAGE] = message if present(message)
      end

      def add_custom_properties(event, properties)
        custom = event['properties']
        return unless custom.is_a?(Hash)

        custom.each { |key, value| properties[key.to_s] = value }
      end

      def build_exception_event(event)
        properties = {}
        add_session_id(event, properties)
        add_conversation_id(event, properties)
        add_person_processing(event, properties)
        add_groups(event, properties)

        error = event['error']
        properties.merge!(error) if error.is_a?(Hash)

        if present(event['resource_name'])
          properties[P::RESOURCE_NAME] = event['resource_name']
          properties[P::TOOL_NAME] = event['resource_name'] if tool_call?(event)
        end
        if present(event['tool_description']) && tool_call?(event)
          properties[P::TOOL_DESCRIPTION] =
            event['tool_description']
        end
        properties[P::TOOL_CATEGORY] = event['tool_category'] if present(event['tool_category']) && tool_call?(event)
        properties[P::SERVER_NAME] = event['server_name'] if present(event['server_name'])
        properties[P::SERVER_VERSION] = event['server_version'] if present(event['server_version'])
        properties[P::CLIENT_NAME] = event['client_name'] if present(event['client_name'])
        properties[P::CLIENT_VERSION] = event['client_version'] if present(event['client_version'])
        properties[P::PROTOCOL_VERSION] = event['protocol_version'] if present(event['protocol_version'])

        add_custom_properties(event, properties)

        { 'event' => Event::EXCEPTION, 'distinct_id' => distinct_id(event), 'properties' => properties,
          'timestamp' => timestamp(event) }
      end

      def present(value)
        return nil if value.nil?
        return nil if value.respond_to?(:empty?) && value.empty?
        return nil if value == false

        value
      end

      def truthy?(value)
        !present(value).nil?
      end
    end
  end
end
