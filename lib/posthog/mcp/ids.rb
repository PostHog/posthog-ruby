# frozen_string_literal: true

require 'securerandom'

module PostHog
  module MCP
    # Id generation: `evt_<uuidv7>` / `ses_<uuidv7>` and the deterministic FNV-1a
    # derivation shared byte-for-byte with posthog-js and posthog-python.
    #
    # @api private
    module Ids
      module_function

      # RFC 9562 UUIDv7 (time-ordered), implemented inline so Ruby 3.0/3.1 work too.
      #
      # @return [String] lowercase, hyphenated uuid
      def uuid_v7
        unix_ts_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) & ((1 << 48) - 1)
        rand_a = SecureRandom.random_number(1 << 12)
        rand_b = SecureRandom.random_number(1 << 62)

        value = unix_ts_ms << 80
        value |= 0x7 << 76
        value |= rand_a << 64
        value |= 0b10 << 62
        value |= rand_b

        hex = format('%032x', value)
        "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
      end

      # @param prefix [String] `'evt'` or `'ses'`
      def new_prefixed_id(prefix)
        "#{prefix}_#{uuid_v7}"
      end

      # Deterministic id derived from an arbitrary string. FNV-1a 64-bit mixed
      # twice to fill 32 hex chars. Not cryptographic; only stable and low-collision.
      #
      # Iterates code points (Python `ord`), which agrees with the JS UTF-16
      # `charCodeAt` port for every BMP input; session/conversation ids are ASCII.
      def deterministic_prefixed_id(prefix, value)
        "#{prefix}_#{fnv1a_hex(value)}#{fnv1a_hex("#{value}::salt")}"
      end

      def fnv1a_hex(value)
        h1 = 0x84222325
        h2 = 0xcbf29ce4
        value.to_s.each_codepoint do |c|
          h1 = ((h1 ^ c) * 0x000001b3) & 0xffffffff
          h2 = ((h2 ^ c) * 0x00000193) & 0xffffffff
        end
        format('%<h1>08x%<h2>08x', h1: h1, h2: h2)
      end
    end
  end
end
