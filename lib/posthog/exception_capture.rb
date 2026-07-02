# frozen_string_literal: true

# Portions of this file are derived from getsentry/sentry-ruby
# Copyright (c) 2020 Sentry
# Licensed under the MIT License: https://github.com/getsentry/sentry-ruby/blob/master/LICENSE
# - sentry-ruby/lib/sentry/interfaces/single_exception.rb
# - sentry-ruby/lib/sentry/interfaces/stacktrace_builder.rb
# - sentry-ruby/lib/sentry/backtrace.rb
# - sentry-ruby/lib/sentry/interfaces/stacktrace.rb
# - sentry-ruby/lib/sentry/linecache.rb

# 💖 open source (under MIT License)

module PostHog
  # Builds PostHog exception payloads from Ruby exception objects.
  #
  # @api private
  module ExceptionCapture
    RUBY_INPUT_FORMAT = /
        ^ \s* (?: [a-zA-Z]: | uri:classloader: )? ([^:]+ | <.*>):
        (\d+)
        (?: :in\s('|`)(?:([\w:]+)\#)?([^']+)')?$
      /x

    # Maximum number of exceptions extracted from a single `cause` chain.
    MAX_CHAINED_EXCEPTIONS = 50

    DEFAULT_MECHANISM = { 'type' => 'generic', 'handled' => true }.freeze

    # Builds the `$exception_list` payload for an exception, walking its
    # `cause` chain outermost-first (wrapper first, root cause last).
    #
    # @param value [Exception, String, Object] Exception input to parse.
    # @param mechanism [Hash, nil] Mechanism applied to the outermost exception,
    #   e.g. `{ 'type' => 'rails', 'handled' => false }`. Chained causes are
    #   tagged with `{ 'type' => 'chained', ... }` and parent linkage.
    # @return [Array<Hash>, nil] Parsed exception payloads, or nil when the input is unsupported.
    def self.build_exception_list(value, mechanism: nil)
      root_mechanism = DEFAULT_MECHANISM.merge(mechanism || {})

      exceptions = []
      seen = {}.compare_by_identity
      current = value

      while current && exceptions.length < MAX_CHAINED_EXCEPTIONS && !seen.key?(current)
        parsed = build_parsed_exception(current, mechanism: chain_mechanism(root_mechanism, exceptions.length))
        break if parsed.nil?

        exceptions << parsed
        seen[current] = true
        current = current.respond_to?(:cause) ? current.cause : nil
      end

      exceptions.empty? ? nil : exceptions
    end

    # @param root_mechanism [Hash] Mechanism of the outermost exception.
    # @param exception_id [Integer] Zero-based position in the cause chain.
    # @return [Hash]
    def self.chain_mechanism(root_mechanism, exception_id)
      mechanism = root_mechanism.merge('exception_id' => exception_id)
      return mechanism if exception_id.zero?

      mechanism.merge(
        'type' => 'chained',
        'source' => 'cause',
        'parent_id' => exception_id - 1
      )
    end

    # @param value [Exception, String, Object] Exception input to parse.
    # @param mechanism [Hash, nil] Mechanism describing how the exception was captured.
    # @return [Hash, nil] Parsed exception payload, or nil when the input is unsupported.
    def self.build_parsed_exception(value, mechanism: nil)
      title, message, backtrace = coerce_exception_input(value)
      return nil if title.nil?

      build_single_exception_from_data(title, message, backtrace, mechanism: mechanism)
    end

    # @param title [String]
    # @param message [String, nil]
    # @param backtrace [Array<String>, nil]
    # @param mechanism [Hash, nil]
    # @return [Hash]
    def self.build_single_exception_from_data(title, message, backtrace, mechanism: nil)
      {
        'type' => title,
        'value' => message || '',
        'mechanism' => DEFAULT_MECHANISM.merge(mechanism || {}),
        'stacktrace' => build_stacktrace(backtrace)
      }
    end

    # @param backtrace [Array<String>, nil]
    # @return [Hash, nil]
    def self.build_stacktrace(backtrace)
      return nil unless backtrace && !backtrace.empty?

      frames = backtrace.first(50).map do |line|
        parse_backtrace_line(line)
      end.compact.reverse

      {
        'type' => 'raw',
        'frames' => frames
      }
    end

    # @param line [String]
    # @return [Hash, nil]
    def self.parse_backtrace_line(line)
      match = line.match(RUBY_INPUT_FORMAT)
      return nil unless match

      file = match[1]
      lineno = match[2].to_i
      method_name = match[5]

      frame = {
        'filename' => File.basename(file),
        'abs_path' => file,
        'lineno' => lineno,
        'function' => method_name,
        'in_app' => !gem_path?(file),
        'platform' => 'ruby'
      }

      add_context_lines(frame, file, lineno) if frame['in_app'] && File.exist?(file)

      frame
    end

    # @param path [String]
    # @return [Boolean]
    def self.gem_path?(path)
      path.include?('/gems/') ||
        path.include?('/ruby/') ||
        path.include?('/.rbenv/') ||
        path.include?('/.rvm/')
    end

    # @param frame [Hash]
    # @param file_path [String]
    # @param lineno [Integer]
    # @param context_size [Integer]
    # @return [void]
    def self.add_context_lines(frame, file_path, lineno, context_size = 5)
      lines = File.readlines(file_path)
      return if lines.empty?

      return unless lineno.positive? && lineno <= lines.length

      pre_context_start = [lineno - context_size, 1].max
      post_context_end = [lineno + context_size, lines.length].min

      frame['context_line'] = lines[lineno - 1].chomp

      frame['pre_context'] = lines[(pre_context_start - 1)...(lineno - 1)].map(&:chomp) if pre_context_start < lineno

      frame['post_context'] = lines[lineno...(post_context_end)].map(&:chomp) if post_context_end > lineno
    rescue StandardError
      # Silently ignore file read errors
    end

    # @param value [Exception, String, Object]
    # @return [Array] Three-item array of title, message, and backtrace.
    def self.coerce_exception_input(value)
      if value.is_a?(String)
        title = 'Error'
        message = value
        backtrace = nil
      elsif value.respond_to?(:backtrace) && value.respond_to?(:message)
        title = value.class.to_s
        message = value.message || ''
        backtrace = value.backtrace
      else
        return [nil, nil, nil]
      end

      [title, message, backtrace]
    end
  end
end
