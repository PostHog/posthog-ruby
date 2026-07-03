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

      root = project_root
      roots = dependency_roots(root)
      frames = backtrace.first(50).map do |line|
        parse_backtrace_line(line, project_root: root, dependency_roots: roots)
      end.compact.reverse

      {
        'type' => 'raw',
        'frames' => frames
      }
    end

    # @param line [String]
    # @param project_root [String, nil] Project root used to derive project-relative filenames.
    # @param dependency_roots [Array<String>, nil] Cached gem and stdlib roots.
    # @return [Hash, nil]
    def self.parse_backtrace_line(line, project_root: self.project_root, dependency_roots: nil)
      match = line.match(RUBY_INPUT_FORMAT)
      return nil unless match

      file = match[1]
      lineno = match[2].to_i
      method_name = match[5]

      frame = {
        'filename' => frame_filename(file, project_root),
        'abs_path' => file,
        'lineno' => lineno,
        'function' => method_name,
        'in_app' => !gem_path?(file, dependency_roots || self.dependency_roots(project_root)),
        'platform' => 'ruby'
      }

      add_context_lines(frame, file, lineno) if frame['in_app'] && File.exist?(file)

      frame
    end

    # Root directory the application runs from, used to derive stable
    # project-relative filenames from per-host deploy paths
    # (e.g. `/app/releases/20240101/...`).
    #
    # @return [String]
    def self.project_root
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.to_s
      else
        Dir.pwd
      end
    rescue StandardError
      Dir.pwd
    end

    # Stable filename used for fingerprinting: the project-relative path when
    # the file lives inside the project root, its basename otherwise. The raw
    # absolute path is kept separately in `abs_path`.
    #
    # @param path [String]
    # @param project_root [String, nil]
    # @return [String]
    def self.frame_filename(path, project_root)
      if project_root && !project_root.empty? && path_within?(path, project_root)
        relative = path[project_root.length..]
        relative = relative[1..] while relative.start_with?(File::SEPARATOR)
        return relative unless relative.empty?
      end

      File.basename(path)
    end

    # Whether the path belongs to an installed gem or the Ruby standard library,
    # based on gem install locations rather than path substrings.
    #
    # @param path [String]
    # @param dependency_roots [Array<String>]
    # @return [Boolean]
    def self.gem_path?(path, dependency_roots = self.dependency_roots)
      dependency_roots.any? { |root| path_within?(path, root) }
    end

    # @param project_root [String]
    # @return [Array<String>] Directories containing installed gems and the Ruby stdlib.
    def self.dependency_roots(project_root = self.project_root)
      roots = []
      if defined?(Gem)
        roots.concat(Gem.path) if Gem.respond_to?(:path)
        roots << Gem.default_dir if Gem.respond_to?(:default_dir)
        roots.concat(Gem.loaded_specs.each_value.map(&:full_gem_path)) if Gem.respond_to?(:loaded_specs)
      end
      roots << RbConfig::CONFIG['rubylibprefix'] if defined?(RbConfig)
      # The project itself can be a loaded spec (e.g. a gem developed in place,
      # or a Rails engine); its frames are still application code.
      roots.compact.reject(&:empty?).uniq - [project_root]
    rescue StandardError
      []
    end

    # @param path [String]
    # @param root [String]
    # @return [Boolean]
    def self.path_within?(path, root)
      root = root.chomp(File::SEPARATOR)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
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
