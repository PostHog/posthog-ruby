# frozen_string_literal: true

# Portions of this file are derived from getsentry/sentry-ruby by Software, Inc. dba Sentry
# Licensed under the MIT License
# - sentry-ruby/lib/sentry/interfaces/single_exception.rb
# - sentry-ruby/lib/sentry/interfaces/stacktrace_builder.rb
# - sentry-ruby/lib/sentry/backtrace.rb
# - sentry-ruby/lib/sentry/interfaces/stacktrace.rb
# - sentry-ruby/lib/sentry/linecache.rb

# 💖 open source (under MIT License)

module PostHog
  module ExceptionCapture
    RUBY_INPUT_FORMAT = /
        ^ \s* (?: [a-zA-Z]: | uri:classloader: )? ([^:]+ | <.*>):
        (\d+)
        (?: :in\s('|`)(?:([\w:]+)\#)?([^']+)')?$
      /x

    def self.build_parsed_exception(value)
      title, message, backtrace = coerce_exception_input(value)
      return nil if title.nil?

      build_single_exception_from_data(title, message, backtrace)
    end

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

      add_context_lines(frame, file, lineno) if File.exist?(file)

      frame
    end

    def self.gem_path?(path)
      path.include?('/gems/') ||
        path.include?('/ruby/') ||
        path.include?('/.rbenv/') ||
        path.include?('/.rvm/')
    end

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

    def self.coerce_exception_input(value)
      if value.is_a?(String)
        title = "Error"
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
