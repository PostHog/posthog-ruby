# frozen_string_literal: true

require 'json'
require 'time'

module PostHog
  module MCP
    # Layered truncation so an event fits within a byte budget before capture:
    #
    # 1. Field-level string limits (intent, resource name, metadata fields).
    # 2. Stack-frame limiting and message caps on the `$exception_list` shape.
    # 3. Response content text limits (32KB per text block).
    # 4. Recursive normalization of user-controlled fields (depth/breadth/string caps).
    # 5. Size-targeted truncation: progressive depth reduction, then trimming the
    #    largest strings until under MAX_EVENT_BYTES.
    #
    # Pure functions; the input event is never mutated. Hash keys are strings.
    #
    # @api private
    module Truncation
      MAX_DEPTH = 10
      MAX_BREADTH = 100
      MAX_STRING_LENGTH = 32_768
      # The core client drops any single message
      # larger than `Defaults::Message::MAX_BYTES` (32KB) at batch time, so the
      # internal event is budgeted to leave headroom for the envelope (`$lib`,
      # timestamp, uuid, distinct_id) the client adds around it.
      MAX_EVENT_BYTES = PostHog::Defaults::Message::MAX_BYTES - 2048

      MAX_USER_INTENT_LENGTH = 2048
      MAX_ERROR_MESSAGE_LENGTH = 2048
      MAX_RESOURCE_NAME_LENGTH = 256
      MAX_METADATA_LENGTH = 256
      MAX_STACK_FRAMES = 50
      MAX_CONTENT_TEXT_LENGTH = 32_768

      TRUNCATION_SUFFIX = '...'

      METADATA_FIELDS = [
        ['user_intent', MAX_USER_INTENT_LENGTH],
        ['resource_name', MAX_RESOURCE_NAME_LENGTH],
        ['server_name', MAX_METADATA_LENGTH],
        ['server_version', MAX_METADATA_LENGTH],
        ['client_name', MAX_METADATA_LENGTH],
        ['client_version', MAX_METADATA_LENGTH],
        ['error_type', MAX_METADATA_LENGTH],
        ['client_user_agent', MAX_METADATA_LENGTH],
        ['vendor_client', MAX_METADATA_LENGTH],
        ['llm_model', MAX_METADATA_LENGTH]
      ].freeze

      # Includes user-supplied `properties` (custom events, `event_properties`,
      # `capture_tool_call`): a large numeric array cannot be shrunk by string
      # trimming, so it must take part in depth/breadth reduction or the core
      # client drops the whole message at batch time.
      NORMALIZED_FIELDS = %w[parameters response identify_actor_data error properties].freeze

      module_function

      # Recursively normalize a value: cap strings, coerce non-serializable
      # values, convert times, detect cycles, and bound depth/breadth.
      def normalize(value, depth = MAX_DEPTH, max_breadth = MAX_BREADTH, max_string_length = MAX_STRING_LENGTH)
        visit(value, depth, max_breadth, max_string_length, {}.compare_by_identity)
      end

      def visit(value, remaining_depth, max_breadth, max_string_length, memo)
        case value
        when nil, true, false, Integer then value
        when Float
          return '[NaN]' if value.nan?
          return (value.positive? ? '[Infinity]' : '[-Infinity]') if value.infinite?

          value
        when String
          value.length > max_string_length ? value[0, max_string_length] + TRUNCATION_SUFFIX : value
        when Symbol then value.to_s
        when Time then value.utc.iso8601(3)
        when Proc, Method
          name = value.respond_to?(:name) ? value.name : nil
          "[Function: #{name || '<anonymous>'}]"
        when Array
          return '[Circular ~]' if memo.key?(value)
          return '[Array]' if remaining_depth <= 0

          memo[value] = true
          result = visit_array(value, remaining_depth - 1, max_breadth, max_string_length, memo)
          memo.delete(value)
          result
        when Hash
          return '[Circular ~]' if memo.key?(value)
          return '[Object]' if remaining_depth <= 0

          memo[value] = true
          result = visit_object(value, remaining_depth - 1, max_breadth, max_string_length, memo)
          memo.delete(value)
          result
        else
          value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
        end
      end

      def visit_array(array, remaining_depth, max_breadth, max_string_length, memo)
        result = []
        array.each_with_index do |item, index|
          if index >= max_breadth
            result << '[MaxProperties ~]'
            break
          end
          result << visit(item, remaining_depth, max_breadth, max_string_length, memo)
        end
        result
      end

      def visit_object(hash, remaining_depth, max_breadth, max_string_length, memo)
        result = {}
        count = 0
        hash.each do |key, val|
          if count >= max_breadth
            result['...'] = '[MaxProperties ~]'
            break
          end
          result[key.to_s] = visit(val, remaining_depth, max_breadth, max_string_length, memo)
          count += 1
        end
        result
      end

      def truncate_string(value, max_length)
        return value unless value.is_a?(String) && value.length > max_length

        value[0, max_length] + TRUNCATION_SUFFIX
      end

      def truncate_stack_frames(frames)
        return frames unless frames.is_a?(Array) && frames.length > MAX_STACK_FRAMES

        half = MAX_STACK_FRAMES / 2
        frames[0, half] + frames[-half, half]
      end

      def truncate_exception_list(error)
        list = error['$exception_list']
        return error unless list.is_a?(Array)

        truncated = list.map do |exception|
          next exception unless exception.is_a?(Hash)

          nxt = exception.dup
          nxt['value'] = truncate_string(nxt['value'], MAX_ERROR_MESSAGE_LENGTH) if nxt['value'].is_a?(String)
          stacktrace = nxt['stacktrace']
          if stacktrace.is_a?(Hash) && stacktrace['frames'].is_a?(Array) && !stacktrace['frames'].empty?
            nxt['stacktrace'] = stacktrace.merge('frames' => truncate_stack_frames(stacktrace['frames']))
          end
          nxt
        end
        error.merge('$exception_list' => truncated)
      end

      def truncate_response_content(response)
        return response unless response.is_a?(Hash)

        content = response['content']
        return response unless content.is_a?(Array)

        new_content = content.map do |block|
          if block.is_a?(Hash) && block['type'] == 'text' && block['text'].is_a?(String) &&
             block['text'].length > MAX_CONTENT_TEXT_LENGTH
            block.merge('text' => block['text'][0, MAX_CONTENT_TEXT_LENGTH] + TRUNCATION_SUFFIX)
          else
            block
          end
        end
        response.merge('content' => new_content)
      end

      # Byte size of the compact JSON encoding, coercing non-JSON values like the
      # transport would.
      def json_byte_size(value)
        JSON.generate(jsonable(value)).bytesize
      end

      def jsonable(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, jsonable(v)] }
        when Array then value.map { |v| jsonable(v) }
        when String, Integer, true, false, nil then value
        when Float then value.finite? ? value : value.to_s
        when Time then value.utc.iso8601(3)
        else
          value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
        end
      end

      def collect_string_paths(obj, current_path, results)
        case obj
        when String
          results << { path: current_path.dup, length: obj.length } if obj.length > 100
        when Array
          obj.each_with_index { |item, i| collect_string_paths(item, current_path + [i.to_s], results) }
        when Hash
          obj.each { |key, value| collect_string_paths(value, current_path + [key.to_s], results) }
        end
      end

      def get_nested_value(obj, path)
        path.reduce(obj) do |current, key|
          case current
          when Array then current[key.to_i]
          when Hash then current[key]
          else return nil
          end
        end
      end

      def set_nested_value(obj, path, value)
        parent = path.empty? ? nil : get_nested_value(obj, path[0...-1])
        case parent
        when Array then parent[path.last.to_i] = value
        when Hash then parent[path.last] = value
        end
      end

      def deep_copy(obj)
        case obj
        when Hash then obj.to_h { |k, v| [k, deep_copy(v)] }
        when Array then obj.map { |v| deep_copy(v) }
        else obj
        end
      end

      def truncate_largest_fields(obj, max_bytes)
        result = deep_copy(obj)

        10.times do
          current_size = json_byte_size(result)
          return result if current_size <= max_bytes

          excess = current_size - max_bytes
          string_paths = []
          collect_string_paths(result, [], string_paths)
          string_paths.sort_by! { |entry| -entry[:length] }
          break if string_paths.empty?

          remaining = excess + 200
          truncated = false
          string_paths.each do |entry|
            break if remaining <= 0

            length = entry[:length]
            reduction = [remaining, length / 2].min
            next if reduction < 10

            new_length = length - reduction
            current_value = get_nested_value(result, entry[:path])
            next unless current_value.is_a?(String)

            set_nested_value(result, entry[:path], current_value[0, new_length] + TRUNCATION_SUFFIX)
            remaining -= reduction
            truncated = true
          end

          break unless truncated
        end

        result
      end

      def truncate_to_size(event)
        return event if json_byte_size(event) <= MAX_EVENT_BYTES

        # Trim the largest strings first so a big tool response keeps its shape
        # (the budget here is tight enough that depth reduction alone would turn
        # a `content` array into "[Array]").
        trimmed = truncate_largest_fields(event, MAX_EVENT_BYTES)
        return trimmed if json_byte_size(trimmed) <= MAX_EVENT_BYTES

        (MAX_DEPTH - 1).downto(1) do |depth|
          reduced = event.dup
          NORMALIZED_FIELDS.each do |field|
            reduced[field] = normalize(reduced[field], depth) unless reduced[field].nil?
          end
          return reduced if json_byte_size(reduced) <= MAX_EVENT_BYTES
        end

        minimal = event.dup
        NORMALIZED_FIELDS.each do |field|
          minimal[field] = normalize(minimal[field], 1) unless minimal[field].nil?
        end
        truncate_largest_fields(minimal, MAX_EVENT_BYTES)
      end

      # @param event [Hash] internal event with string keys
      # @return [Hash] new event within the byte budget
      def truncate_event(event)
        result = event.dup

        METADATA_FIELDS.each do |key, max_length|
          result[key] = truncate_string(result[key], max_length) if result[key].is_a?(String)
        end

        result['error'] = truncate_exception_list(result['error']) if result['error'].is_a?(Hash)
        result['response'] = truncate_response_content(result['response']) unless result['response'].nil?

        NORMALIZED_FIELDS.each do |field|
          result[field] = normalize(result[field]) unless result[field].nil?
        end

        truncate_to_size(result)
      end
    end
  end
end
