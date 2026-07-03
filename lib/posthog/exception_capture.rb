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

    # @param value [Exception, String, Object] Exception input to parse.
    # @return [Hash, nil] Parsed exception payload, or nil when the input is unsupported.
    def self.build_parsed_exception(value)
      title, message, backtrace = coerce_exception_input(value)
      return nil if title.nil?

      build_single_exception_from_data(title, message, backtrace)
    end

    # @param title [String]
    # @param message [String, nil]
    # @param backtrace [Array<String>, nil]
    # @return [Hash]
    def self.build_single_exception_from_data(title, message, backtrace)
      {
        'type' => title,
        'value' => message || '',
        'mechanism' => {
          'type' => 'generic',
          'handled' => true
        },
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

      in_app = !gem_path?(file)

      frame = {
        'filename' => compute_filename(file, in_app),
        'abs_path' => file,
        'lineno' => lineno,
        'function' => method_name,
        'in_app' => in_app,
        'platform' => 'ruby'
      }

      add_context_lines(frame, file, lineno) if frame['in_app'] && File.exist?(file)

      frame
    end

    # @param path [String]
    # @param in_app [Boolean]
    # @return [String]
    def self.compute_filename(path, in_app)
      return path unless absolute_path?(path)

      prefixes = in_app ? [rails_root, Dir.pwd] : $LOAD_PATH
      strip_path_prefix(path, prefixes) || path
    end

    # @param path [String]
    # @param prefixes [Array<String, nil>]
    # @return [String, nil]
    def self.strip_path_prefix(path, prefixes)
      normalized_path = normalize_path(path)
      normalized_prefixes = prefixes.compact.map do |prefix|
        normalize_path(File.expand_path(prefix.to_s))
      end

      normalized_prefixes
        .select { |prefix| normalized_path.start_with?("#{prefix}/") }
        .max_by(&:length)
        &.then { |prefix| normalized_path[(prefix.length + 1)..] }
    end

    # @param path [String]
    # @return [String]
    def self.normalize_path(path)
      path.tr('\\', '/').sub(%r{/+\z}, '')
    end

    # @return [String, nil]
    def self.rails_root
      return nil unless Object.const_defined?(:Rails)

      rails = Object.const_get(:Rails)
      return nil unless rails.respond_to?(:root) && rails.root

      rails.root.to_s
    rescue StandardError
      nil
    end

    # @param path [String]
    # @return [Boolean]
    def self.absolute_path?(path)
      path.start_with?('/') || path.match?(%r{\A[a-zA-Z]:[/\\]})
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
