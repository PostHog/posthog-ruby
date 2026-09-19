# frozen_string_literal: true

module PostHog
  module MCP
    # Injects analytics parameters (`context`, `conversation_id`, `llm_model`)
    # into advertised tool input schemas and declares `_mcp_instructions` on
    # output schemas. Always returns new hashes: the `mcp` gem's `Tool.to_h`
    # shares its nested schema hashes with the tool class, so in-place writes
    # would leak into the tool permanently.
    #
    # Works on symbol- or string-keyed schemas and writes back in the input's key style.
    #
    # @api private
    module SchemaMutation
      COMPLEX_KEYS = %w[oneOf allOf anyOf].freeze

      module_function

      def fetch(hash, name)
        return nil unless hash.is_a?(Hash)

        hash.key?(name.to_sym) ? hash[name.to_sym] : hash[name.to_s]
      end

      def key_for(hash, name)
        return name.to_sym if hash.key?(name.to_sym)
        return name.to_s if hash.key?(name.to_s)

        hash.keys.first.is_a?(String) ? name.to_s : name.to_sym
      end

      def declares_param?(schema, name)
        properties = fetch(schema, :properties)
        properties.is_a?(Hash) && (properties.key?(name.to_sym) || properties.key?(name.to_s))
      end

      def complex?(schema)
        COMPLEX_KEYS.any? { |key| truthy?(fetch(schema, key)) }
      end

      # Whether an analytics parameter may be injected into (and therefore owned
      # in) this input schema. A composed (oneOf/allOf/anyOf) or referenced
      # ($ref) schema can declare the property out of band, and a sibling
      # property next to a reference to a closed object makes the schema
      # unsatisfiable, so those are left alone entirely.
      def injectable?(schema)
        return true unless schema.is_a?(Hash)

        !complex?(schema) && !truthy?(fetch(schema, :$ref))
      end

      # Key style of `hash`, falling back to `parent`'s when `hash` is empty.
      def string_keys?(hash, parent)
        source = hash.empty? ? parent : hash
        source.keys.first.is_a?(String)
      end

      def truthy?(value)
        !(value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?))
      end

      def deep_dup(value)
        case value
        when Hash then value.to_h { |k, v| [k, deep_dup(v)] }
        when Array then value.map { |v| deep_dup(v) }
        else value
        end
      end

      # Add a string property to an object schema. Returns the input unchanged
      # (logging a warning) when the property exists or the schema is composed
      # or referenced.
      #
      # @return [Hash] new schema
      def add_parameter(schema, name, description, tool_name:, required:, options: nil, label: name)
        if declares_param?(schema, name)
          Log.debug(options,
                    "WARN: Tool \"#{tool_name}\" already has '#{name}' parameter. Skipping #{label} injection.")
          return schema
        end
        unless injectable?(schema)
          Log.debug(options,
                    "WARN: Tool \"#{tool_name}\" has a composed schema (oneOf/allOf/anyOf/$ref). " \
                    "Skipping #{label} injection.")
          return schema
        end

        if schema.nil? || (schema.respond_to?(:empty?) && schema.empty?)
          schema = { type: 'object', properties: {},
                     required: [] }
        end
        schema = deep_dup(schema)
        properties_key = key_for(schema, :properties)
        schema[properties_key] = {} unless schema[properties_key].is_a?(Hash)

        # `additionalProperties: false` stays: the injected name is listed under
        # `properties`, so it is still accepted, and relaxing the constraint would
        # advertise a looser schema than the dispatcher actually validates against.
        property_key = string_keys?(schema[properties_key], schema) ? name.to_s : name.to_sym
        schema[properties_key][property_key] = { type: 'string', description: description }

        if required
          required_key = key_for(schema, :required)
          if schema[required_key].is_a?(Array)
            schema[required_key] << name.to_s unless schema[required_key].map(&:to_s).include?(name.to_s)
          else
            schema[required_key] = [name.to_s]
          end
        end
        schema
      end

      def add_context_parameter(schema, tool_name:, description: nil, required: true, options: nil)
        add_parameter(schema, 'context', description || DEFAULT_CONTEXT_PARAMETER_DESCRIPTION,
                      tool_name: tool_name, required: required, options: options, label: 'context')
      end

      def add_conversation_id_parameter(schema, tool_name:, options: nil)
        add_parameter(schema, ConversationId::PARAM_NAME, DEFAULT_CONVERSATION_ID_DESCRIPTION,
                      tool_name: tool_name, required: false, options: options, label: 'conversation_id')
      end

      def add_model_parameter(schema, tool_name:, description: nil, required: true, options: nil)
        add_parameter(schema, ModelCapture::PARAM_NAME, description || DEFAULT_MODEL_PARAMETER_DESCRIPTION,
                      tool_name: tool_name, required: required, options: options, label: 'llm_model')
      end

      # Whether `_mcp_instructions` can safely be declared on this output schema.
      def declarable_output?(schema)
        return false unless schema.is_a?(Hash)
        return false if truthy?(fetch(schema, :$ref)) || complex?(schema)

        properties = fetch(schema, :properties)
        return false if !properties.nil? && !properties.is_a?(Hash)

        !truthy?(properties) || !declares_param?(schema, ConversationId::MCP_INSTRUCTIONS_KEY)
      end

      def our_declaration?(declaration)
        declaration.is_a?(Hash) && fetch(declaration, :description) == ConversationId::INSTRUCTIONS_FIELD_DESCRIPTION
      end

      # Declare an optional `_mcp_instructions` on the output schema.
      #
      # @return [Array(Hash, Boolean)] `[schema, declared]`
      def add_output_instructions(schema, tool_name:, options: nil)
        return [schema, false] if schema.nil? || (schema.respond_to?(:empty?) && schema.empty?)

        key = ConversationId::MCP_INSTRUCTIONS_KEY
        unless declarable_output?(schema)
          properties = fetch(schema, :properties)
          if properties.is_a?(Hash) && declares_param?(schema, key)
            return [schema, true] if our_declaration?(fetch(properties, key))

            Log.debug(options,
                      "WARN: Tool \"#{tool_name}\" already declares '#{key}' in its output schema. Leaving it alone.")
          else
            Log.debug(options, "WARN: Tool \"#{tool_name}\" has a complex output schema (oneOf/allOf/anyOf/$ref). " \
                               "Skipping '#{key}' declaration; its session handle stays content-only.")
          end
          return [schema, false]
        end

        schema = deep_dup(schema)
        properties_key = key_for(schema, :properties)
        schema[properties_key] = {} unless schema[properties_key].is_a?(Hash)
        property_key = string_keys?(schema[properties_key], schema) ? key : key.to_sym
        schema[properties_key][property_key] = {
          type: 'object',
          description: ConversationId::INSTRUCTIONS_FIELD_DESCRIPTION,
          properties: {
            conversation_id: { type: 'string', description: ConversationId::CONVERSATION_ID_FIELD_DESCRIPTION }
          }
        }
        [schema, true]
      end
    end
  end
end
