# frozen_string_literal: true

require 'json'
require 'set'
require 'uri'

module PostHog
  module MCP
    # Event sanitization: redact non-text response content blocks, large base64
    # strings, PostHog tokens, credential-looking words, and sensitive keys.
    # Pure functions that return new objects without mutating the input; run
    # before truncation. Hash keys are strings.
    #
    # @api private
    module Sanitization
      INJECTED_ARGUMENT_NAMES = %w[context conversation_id llm_model].freeze
      REDACTED_VALUE = '[redacted]'
      BINARY_REDACTED_VALUE = '[binary data redacted - not supported by PostHog MCP analytics]'
      BASE64_PATTERN = %r{\A[A-Za-z0-9+/\n\r]+=*\z}
      BASE64URL_PATTERN = /\A[A-Za-z0-9_-]+={0,2}\z/
      BASE64URL_SPECIFIC_CHAR_PATTERN = /[-_]/
      BASE64_DATA_URL_PREFIX_PATTERN = /\Adata:[^,\s]*;base64,/i
      BASE64_DATA_URL_PAYLOAD_PATTERN = %r{\A[A-Za-z0-9+/_-]+={0,2}\z}
      SIZE_GATE = 10_240
      POSTHOG_TOKEN_PATTERN = /\bph[a-z]_[A-Za-z0-9_-]{20,}\b/
      SENSITIVE_KEY_PATTERN = /\A(authorization|cookie|set-cookie|x-api-key|api[-_]?key|api[-_]?token|
        access[-_]?token|refresh[-_]?token|token|password|secret|client[-_]?secret|private[-_]?key)\z/ix

      # PII redaction for the agent-narrated intent string only. Ordered so an
      # earlier pass never eats digits a later pass needs. `\d`, `\w` and `\b`
      # are ASCII-only in Ruby, which is what these patterns assume.
      UNICODE_SPACE_PATTERN = /[\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]/
      EMAIL_PATTERN = /[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,255}\.[A-Za-z]{2,24}/
      IPV4_PATTERN = /\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b/
      IPV6_PATTERN = /
        \b(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}\b
        |(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){1,7}:(?![\w:])
        |(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,5}(?!\w)
        |(?<![\w:])::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})(?!\w)
      /x
      US_SSN_PATTERN = /\b\d{3}[ .-]\d{2}[ .-]\d{4}\b/
      CREDIT_CARD_CANDIDATE_PATTERN = %r{\b\d(?:[ ./-]?\d){12,}\b}
      DIGIT_GROUP_PATTERN = /\d+/
      PHONE_NANP_PATTERN = %r{(?<![\w+])(?:\+?1[ ./-]?)?(?:\(\d{3}\)[ ./-]?|\d{3}[ ./-])\d{3}[ ./-]\d{4}(?!\w)}
      PHONE_INTL_PATTERN = %r{(?<!\w)\+\d{1,3}(?:[ ./()-]{0,2}\d){7,13}(?!\w)}

      module_function

      # Deep-copies a value with string keys so the pipeline can rely on one shape.
      def stringify_keys(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, stringify_keys(v)] }
        when Array then value.map { |v| stringify_keys(v) }
        else value
        end
      end

      def redact_key?(key)
        SENSITIVE_KEY_PATTERN.match?(key.to_s)
      end

      def base64_data_url?(value)
        prefix = BASE64_DATA_URL_PREFIX_PATTERN.match(value)
        return false unless prefix

        payload = decode_percent(value[prefix[0].length..])
        return false if payload.nil?

        BASE64_DATA_URL_PAYLOAD_PATTERN.match?(payload.delete("\r\n"))
      end

      # Percent-decoding only: `+` is a base64 character, so form decoding
      # (which turns it into a space) would break detection of valid data URLs.
      def decode_percent(value)
        if URI.respond_to?(:decode_uri_component)
          URI.decode_uri_component(value)
        else
          URI::DEFAULT_PARSER.unescape(value)
        end
      rescue ArgumentError
        nil
      end

      def binary_like?(value)
        return false unless value.length >= SIZE_GATE

        BASE64_PATTERN.match?(value) ||
          base64_data_url?(value) ||
          (BASE64URL_SPECIFIC_CHAR_PATTERN.match?(value) && BASE64URL_PATTERN.match?(value))
      end

      def sanitize_string(value)
        return BINARY_REDACTED_VALUE if binary_like?(value)

        redact_secret_tokens(value.gsub(POSTHOG_TOKEN_PATTERN, REDACTED_VALUE))
      end

      # Redact credential-looking words, leaving surrounding text intact.
      def redact_secret_tokens(value)
        return (SecretDetection.secret?(value) ? REDACTED_VALUE : value) unless value.include?(' ')

        value.split(' ', -1).map { |word| SecretDetection.secret?(word) ? REDACTED_VALUE : word }.join(' ')
      end

      def passes_luhn?(digits)
        total = 0
        double = false
        (digits.length - 1).downto(0) do |index|
          digit = digits.getbyte(index) - 48
          return false if digit.negative? || digit > 9

          if double
            digit *= 2
            digit -= 9 if digit > 9
          end
          total += digit
          double = !double
        end
        (total % 10).zero?
      end

      # Within a card candidate, redact every run of whole separator-delimited
      # digit groups whose joined digits are 13-19 long and pass Luhn.
      def redact_card_in_match(text)
        groups = []
        text.scan(DIGIT_GROUP_PATTERN) do
          groups << [Regexp.last_match[0], Regexp.last_match.begin(0), Regexp.last_match.end(0)]
        end
        output = +''
        cursor = 0
        first = 0
        while first < groups.length
          digits = +''
          matched_last = -1
          (first...groups.length).each do |last|
            digits << groups[last][0]
            break if digits.length > 19

            matched_last = last if digits.length >= 13 && passes_luhn?(digits)
          end
          if matched_last >= 0
            output << text[cursor...groups[first][1]] << REDACTED_VALUE
            cursor = groups[matched_last][2]
            first = matched_last + 1
          else
            first += 1
          end
        end
        output << text[cursor..]
      end

      # Redact structured personal identifiers (emails, IPs, cards, US SSNs,
      # phone numbers) from free text. Intended for `$mcp_intent` only.
      def redact_pii(value)
        return value unless value.is_a?(String)

        result = value.gsub(UNICODE_SPACE_PATTERN, ' ')
        result = result.gsub(EMAIL_PATTERN, REDACTED_VALUE)
        result = result.gsub(IPV4_PATTERN, REDACTED_VALUE)
        result = result.gsub(IPV6_PATTERN, REDACTED_VALUE)
        result = result.gsub(CREDIT_CARD_CANDIDATE_PATTERN) { |match| redact_card_in_match(match) }
        result = result.gsub(US_SSN_PATTERN, REDACTED_VALUE)
        result = result.gsub(PHONE_NANP_PATTERN, REDACTED_VALUE)
        result.gsub(PHONE_INTL_PATTERN, REDACTED_VALUE)
      end

      def sanitize_captured_value(value)
        case value
        when nil then nil
        when String then sanitize_string(value)
        when Array then value.map { |item| sanitize_captured_value(item) }
        when Hash
          value.to_h do |key, nested|
            [key.to_s, redact_key?(key) ? REDACTED_VALUE : sanitize_captured_value(nested)]
          end
        else value
        end
      end

      # Sanitize an event's response, parameters, intent and error. Returns a
      # new shallow copy; does not mutate the input.
      def sanitize_event(event)
        result = event.dup
        result['response'] = sanitize_response(result['response']) unless result['response'].nil?
        result['parameters'] = sanitize_captured_value(result['parameters']) unless result['parameters'].nil?
        unless result['user_intent'].nil?
          result['user_intent'] = redact_pii(sanitize_captured_value(result['user_intent']))
        end
        result['error'] = sanitize_exception_values(result['error']) unless result['error'].nil?
        result
      end

      def sanitize_exception_values(error)
        return error unless error.is_a?(Hash)

        list = error['$exception_list']
        return error unless list.is_a?(Array)

        error.merge(
          '$exception_list' => list.map do |exception|
            exception.is_a?(Hash) ? exception.merge('value' => sanitize_captured_value(exception['value'])) : exception
          end
        )
      end

      def sanitize_response(response)
        unless response.is_a?(Hash) || response.is_a?(Array) || response.is_a?(String)
          return sanitize_captured_value(response)
        end

        sanitized = sanitize_captured_value(response)
        return sanitized unless sanitized.is_a?(Hash)

        result = sanitized.dup
        if result['content'].is_a?(Array)
          result['content'] = result['content'].map do |block|
            sanitize_content_block(block)
          end
        end
        structured = result['structuredContent']
        if structured.is_a?(Hash) || structured.is_a?(Array)
          result['structuredContent'] =
            sanitize_captured_value(structured)
        end
        result
      end

      def sanitize_content_block(block)
        return block unless block.is_a?(Hash)

        case block['type']
        when 'text', 'resource_link' then sanitize_captured_value(block)
        when 'image' then text_block('[image content redacted - not supported by PostHog MCP analytics]')
        when 'audio' then text_block('[audio content redacted - not supported by PostHog MCP analytics]')
        when 'resource'
          resource = block['resource']
          if resource.is_a?(Hash) && resource.key?('blob')
            text_block('[binary resource content redacted - not supported by PostHog MCP analytics]')
          else
            sanitize_captured_value(block)
          end
        else
          text_block("[unsupported content type \"#{block['type']}\" redacted - " \
                     'not supported by PostHog MCP analytics]')
        end
      end

      def text_block(text)
        { 'type' => 'text', 'text' => text }
      end

      # Build the sanitized `$mcp_parameters` payload from a JSON-RPC request,
      # dropping the SDK-injected arguments (they surface as dedicated properties).
      def build_captured_mcp_parameters(request)
        request = stringify_keys(request)
        return { 'request' => sanitize_captured_value(request) } unless request.is_a?(Hash)

        captured = {}
        %w[id jsonrpc method].each do |key|
          captured[key] = sanitize_captured_value(request[key]) if request.key?(key)
        end
        captured['params'] = build_captured_params(request['params']) if request.key?('params')
        { 'request' => captured }
      end

      def build_captured_params(params)
        return sanitize_captured_value(params) unless params.is_a?(Hash)

        params.to_h do |key, value|
          [key, key == 'arguments' ? build_captured_arguments(value) : sanitize_captured_value(value)]
        end
      end

      def build_captured_arguments(arguments)
        return sanitize_captured_value(arguments) unless arguments.is_a?(Hash)

        arguments.each_with_object({}) do |(key, value), captured|
          next if INJECTED_ARGUMENT_NAMES.include?(key)

          captured[key] = sanitize_captured_value(value)
        end
      end

      # Last-resort credential detection for bare words.
      #
      # @api private
      module SecretDetection
        MIN_LENGTH = 16
        MIN_ENTROPY_BITS = 3.8
        MIN_CHAR_CLASSES = 3
        HEX_DIGITS = '0123456789abcdefABCDEF'.chars.to_set.freeze
        REJECT_CHARS = "()[]{}<>'\"`,;".chars.to_set.freeze
        UUID_RE = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
        PATH_WORD_RE = /\A[a-z][a-z.]*\z/
        PEM_PRIVATE_KEY_MARKER = 'PRIVATE KEY-----'
        KNOWN_SECRET_MAX_SCAN_LENGTH = 200
        KNOWN_SECRET_RE = Regexp.union(
          /sk-ant-[A-Za-z0-9_-]{16,}/,
          /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/,
          /hf_[A-Za-z0-9]{34}/,
          /AKIA[0-9A-Z]{16}/,
          /(?:ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ABIA|ACCA)[0-9A-Z]{16}/,
          /AIza[A-Za-z0-9_-]{35}/,
          /ya29\.[A-Za-z0-9_-]{20,}/,
          /do[opr]_v1_[a-f0-9]{64}/,
          /(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}/,
          /sq0[a-z]{3}-[A-Za-z0-9_-]{22,43}/,
          /gh[pousr]_[A-Za-z0-9]{36}/,
          /github_pat_[A-Za-z0-9_]{20,}/,
          /gl(?:pat|ptt|rt|soat)-[A-Za-z0-9_-]{20}/,
          /glsa_[A-Za-z0-9]{32}_[A-Fa-f0-9]{8}/,
          /xox[abeoprs]-[A-Za-z0-9-]{10,}/,
          /xapp-[0-9]-[A-Za-z0-9-]{10,}/,
          /SK[0-9a-fA-F]{32}/,
          /SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}/,
          /key-[0-9a-f]{32}/,
          /[0-9a-f]{32}-us[0-9]{1,2}/,
          /npm_[A-Za-z0-9]{36}/,
          /pypi-AgEI[A-Za-z0-9_-]{50,}/,
          /dapi[0-9a-f]{32}/,
          /dp\.pt\.[A-Za-z0-9]{40,}/,
          /PMAK-[a-f0-9]{24}-[a-f0-9]{34}/,
          /lin_api_[A-Za-z0-9]{40}/,
          /ntn_[A-Za-z0-9]{40,}/,
          /shp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}/,
          /NR(?:AK|JS|II|MA|RA)-[A-Za-z0-9]{27}/,
          /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}/
        )

        module_function

        def secret?(value)
          return false unless value.is_a?(String) && !value.empty?
          return true if value.include?(PEM_PRIVATE_KEY_MARKER)

          n = value.length
          return false if n < MIN_LENGTH
          return true if high_entropy_secret?(value)
          return KNOWN_SECRET_RE.match?(value) if n <= KNOWN_SECRET_MAX_SCAN_LENGTH

          false
        rescue StandardError
          false
        end

        def path_or_url?(value)
          return true if value.include?('://') || value.include?('\\')
          return false unless value.include?('/')

          value.split('/').count { |segment| !segment.empty? && PATH_WORD_RE.match?(segment) } >= 2
        end

        def high_entropy_secret?(value)
          return false if value.include?(' ') || path_or_url?(value) || UUID_RE.match?(value)

          counts = value.each_char.tally
          distinct = counts.keys
          return false if distinct.any? { |ch| REJECT_CHARS.include?(ch) }

          has_lower = has_upper = has_digit = has_symbol = false
          hex_only = true
          distinct.each do |ch|
            return false if ch.match?(/\s/)

            case ch
            when /[[:lower:]]/
              has_lower = true
              hex_only = false unless HEX_DIGITS.include?(ch)
            when /[[:upper:]]/
              has_upper = true
              hex_only = false unless HEX_DIGITS.include?(ch)
            when /[[:digit:]]/
              has_digit = true
            else
              has_symbol = true
              hex_only = false
            end
          end
          return false if hex_only
          return false if [has_lower, has_upper, has_digit, has_symbol].count(true) < MIN_CHAR_CLASSES

          n = value.length.to_f
          entropy = counts.values.sum do |occurrences|
            p = occurrences / n
            -p * Math.log2(p)
          end
          entropy >= MIN_ENTROPY_BITS
        end
      end
    end
  end
end
