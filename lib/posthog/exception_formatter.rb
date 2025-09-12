# frozen_string_literal: true

require 'digest'

module PostHog
  # Formats Ruby exceptions for PostHog's $exception event format
  class ExceptionFormatter
    class << self
      # Formats a Ruby exception into PostHog's expected $exception_list format
      #
      # @param [Exception] exception The exception to format
      # @param [Hash] options Additional formatting options
      # @option options [Boolean] :handled Whether the exception was handled (default: true)
      # @option options [String] :mechanism_type The mechanism type (default: 'generic')
      # @return [Hash] The formatted exception data
      def format_exception(exception, options = {})
        {
          type: exception.class.name,
          value: exception.message.to_s,
          mechanism: {
            handled: options.fetch(:handled, true),
            synthetic: false,
            type: options.fetch(:mechanism_type, 'generic')
          },
          stacktrace: format_stacktrace(exception.backtrace || [])
        }
      end

      # Generates a fingerprint for exception grouping
      #
      # @param [Exception] exception The exception to fingerprint
      # @param [String, nil] custom_fingerprint Custom fingerprint override
      # @return [String] The exception fingerprint
      def generate_fingerprint(exception, custom_fingerprint = nil)
        return custom_fingerprint if custom_fingerprint

        # Create fingerprint based on exception class and cleaned backtrace
        fingerprint_data = [
          exception.class.name,
          normalized_message(exception.message),
          top_application_frames(exception.backtrace || []).join('\n')
        ].join('|')

        Digest::SHA256.hexdigest(fingerprint_data)
      end

      private

      # Formats exception backtrace into PostHog's stacktrace format
      #
      # @param [Array<String>] backtrace The exception backtrace
      # @return [Hash] The formatted stacktrace
      def format_stacktrace(backtrace)
        return { frames: [], type: 'resolved' } if backtrace.empty?

        frames = backtrace.map.with_index do |line, index|
          parse_backtrace_line(line, index)
        end.compact

        {
          frames: frames.reverse, # PostHog expects frames in reverse order (newest first)
          type: 'resolved'
        }
      end

      # Parses a single backtrace line into PostHog frame format
      #
      # @param [String] line The backtrace line
      # @param [Integer] index The frame index
      # @return [Hash, nil] The parsed frame or nil if unparseable
      def parse_backtrace_line(line, index)
        # Ruby backtrace format: "filename:line:in `method'"
        match = line.match(/^(.+?):(\d+)(?::in `(.+?)')?/)
        return nil unless match

        filename, line_number, method_name = match.captures

        # Determine if this is application code vs library code
        in_app = application_file?(filename)

        {
          filename: filename,
          lineno: line_number.to_i,
          function: method_name || '<unknown>',
          in_app: in_app,
          raw_id: generate_frame_id(filename, line_number, method_name),
          resolved: true,
          lang: 'ruby'
        }
      end

      # Generates a unique ID for a stack frame
      #
      # @param [String] filename The filename
      # @param [String] line_number The line number
      # @param [String, nil] method_name The method name
      # @return [String] The frame ID
      def generate_frame_id(filename, line_number, method_name)
        frame_data = "#{filename}:#{line_number}:#{method_name}"
        Digest::SHA256.hexdigest(frame_data)
      end

      # Determines if a file is application code (vs gem/library code)
      #
      # @param [String] filename The filename to check
      # @return [Boolean] True if this is application code
      def application_file?(filename)
        return false if filename.include?('/gems/')
        return false if filename.include?('/ruby/')
        return false if filename.include?('/bundler/')
        return false if filename.include?('/rbenv/')

        # Consider it application code if it's in common app directories
        return true if filename.include?('/app/')
        return true if filename.include?('/lib/') && !filename.include?('/usr/local/lib/')
        return true if filename.include?('/config/')

        # Consider relative paths as application code
        !filename.start_with?('/')
      end

      # Normalizes exception messages for consistent fingerprinting
      #
      # @param [String, nil] message The exception message
      # @return [String] The normalized message
      def normalized_message(message)
        return '' unless message

        # Remove dynamic content like IDs, timestamps, etc. for better grouping
        message.to_s
          .gsub(/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}/, '<TIMESTAMP>')  # timestamps
          .gsub(/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/i, '<UUID>')  # UUIDs (before numbers)
          .gsub(/\b\d+\b/, '<NUMBER>')  # standalone numbers
          .gsub(/0x[0-9a-fA-F]+/, '<HEX>')  # hex addresses
          .strip
      end

      # Extracts top application frames for fingerprinting
      #
      # @param [Array<String>] backtrace The exception backtrace
      # @param [Integer] max_frames Maximum frames to include
      # @return [Array<String>] The top application frames
      def top_application_frames(backtrace, max_frames = 5)
        application_frames = backtrace.select { |line| application_file?(line.split(':').first || '') }
        application_frames.first(max_frames)
      end
    end
  end
end