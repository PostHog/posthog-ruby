# frozen_string_literal: true

require 'securerandom'

module PostHog
  # UUID generation helpers used by SDK-generated identifiers.
  #
  # @api private
  module Uuid
    module_function

    def v7
      return SecureRandom.uuid_v7 if SecureRandom.respond_to?(:uuid_v7)

      bytes = uuid_v7_bytes
      hex = bytes.pack('C*').unpack1('H*')
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    def uuid_v7_bytes
      timestamp_ms = (Time.now.to_f * 1000).to_i & 0xffffffffffff
      bytes = [
        (timestamp_ms >> 40) & 0xff,
        (timestamp_ms >> 32) & 0xff,
        (timestamp_ms >> 24) & 0xff,
        (timestamp_ms >> 16) & 0xff,
        (timestamp_ms >> 8) & 0xff,
        timestamp_ms & 0xff,
        *SecureRandom.bytes(10).bytes
      ]

      bytes[6] = (bytes[6] & 0x0f) | 0x70
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      bytes
    end
    private_class_method :uuid_v7_bytes
  end
end
