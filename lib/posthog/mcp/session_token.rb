# frozen_string_literal: true

require 'base64'
require 'json'

module PostHog
  module MCP
    # What a self-encoded `Mcp-Session-Id` token carries.
    #
    # @!attribute session_id
    #   @return [String] PostHog session id (`ses_...`) -> `$session_id`
    # @!attribute client_name
    #   @return [String, nil] MCP client name -> `$mcp_client_name`
    # @!attribute client_version
    #   @return [String, nil] MCP client version -> `$mcp_client_version`
    # @!attribute protocol_version
    #   @return [String, nil] MCP protocol version -> `$mcp_protocol_version`
    SessionTokenPayload = Struct.new(:session_id, :client_name, :client_version, :protocol_version, keyword_init: true)

    # Self-encoded session tokens for stateless / multi-pod MCP servers.
    #
    # A stateless server keeps nothing between requests, so every request would
    # start a new session and the client identity (only sent at `initialize`)
    # would be lost. Clients replay the `Mcp-Session-Id` header on every request,
    # so at `initialize` we mint that header as an unsigned base64url(JSON) token
    # with short keys (`sid`, `cn`, `cv`, `pv`). Wire-compatible with the JS and
    # Python SDKs.
    #
    # @api private
    module SessionToken
      MAX_TOKEN_LENGTH = 4096
      MAX_SESSION_ID_LENGTH = 128
      MAX_CLIENT_FIELD_LENGTH = 200
      BASE64URL_PATTERN = /\A[A-Za-z0-9_-]+={0,2}\z/

      module_function

      # @param payload [SessionTokenPayload, Hash]
      # @return [String] token for the `Mcp-Session-Id` response header
      # @raise [ArgumentError] when `session_id` is missing or empty
      def encode(payload)
        payload = SessionTokenPayload.new(**payload) if payload.is_a?(Hash)
        session_id = payload.session_id
        unless session_id.is_a?(String) && !session_id.empty?
          raise ArgumentError, 'encode_session_id requires a non-empty `session_id` (use new_session_id())'
        end

        wire = { 'sid' => session_id }
        wire['cn'] = payload.client_name[0, MAX_CLIENT_FIELD_LENGTH] if present_string?(payload.client_name)
        wire['cv'] = payload.client_version[0, MAX_CLIENT_FIELD_LENGTH] if present_string?(payload.client_version)
        wire['pv'] = payload.protocol_version[0, MAX_CLIENT_FIELD_LENGTH] if present_string?(payload.protocol_version)
        Base64.urlsafe_encode64(JSON.generate(wire), padding: false)
      end

      # Decode an `Mcp-Session-Id` value. Returns nil for anything that is not one
      # of our tokens (transport UUIDs, JWTs, garbage) and never raises.
      #
      # @return [SessionTokenPayload, nil]
      def decode(value)
        return nil unless value.is_a?(String) && !value.empty? && value.length <= MAX_TOKEN_LENGTH
        return nil unless BASE64URL_PATTERN.match?(value)

        parsed = begin
          JSON.parse(Base64.urlsafe_decode64(value.delete('=')))
        rescue ArgumentError, JSON::ParserError, EncodingError
          nil
        end
        return nil unless parsed.is_a?(Hash)

        sid = parsed['sid']
        return nil unless sid.is_a?(String) && !sid.empty? && sid.length <= MAX_SESSION_ID_LENGTH

        payload = SessionTokenPayload.new(session_id: sid)
        payload.client_name = parsed['cn'][0, MAX_CLIENT_FIELD_LENGTH] if present_string?(parsed['cn'])
        payload.client_version = parsed['cv'][0, MAX_CLIENT_FIELD_LENGTH] if present_string?(parsed['cv'])
        payload.protocol_version = parsed['pv'][0, MAX_CLIENT_FIELD_LENGTH] if present_string?(parsed['pv'])
        payload
      end

      # Read the `mcp-session-id` value off a headers Hash (case-insensitive keys,
      # array values, trimmed). Returns nil when absent or blank.
      def read_header(headers)
        return nil unless headers.respond_to?(:each_pair)

        value = headers[MCP_SESSION_HEADER]
        if value.nil?
          headers.each_pair do |key, candidate|
            next unless key.is_a?(String) && key.downcase == MCP_SESSION_HEADER

            value = candidate
            break
          end
        end
        value = value.first if value.is_a?(Array)
        return nil unless value.is_a?(String)

        trimmed = value.strip
        trimmed.empty? ? nil : trimmed
      end

      def present_string?(value)
        value.is_a?(String) && !value.empty?
      end
      private_class_method :present_string?
    end
  end
end
