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

    def self.build_exception_properties(exception, additional_properties = {})
      exception_info = build_single_exception(exception)
      
      properties = {
        '$exception_type' => exception_info['type'],
        '$exception_value' => exception_info['value'],
        '$exception_list' => [exception_info]
      }
      
      properties.merge!(additional_properties) if additional_properties

      properties
    end

    private

    def self.build_single_exception(exception)
      {
        'type' => exception.class.to_s,
        'value' => exception.message || "",
        'mechanism' => {
          'type' => 'generic',
          'handled' => true
        },
        'stacktrace' => build_stacktrace(exception.backtrace)
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
      module_name = match[4]  # Optional module/class name
      method_name = match[5]
      
      frame = {
        'filename' => File.basename(file),
        'abs_path' => file,
        'lineno' => lineno,
        'function' => method_name,
        'in_app' => !is_gem_path?(file),
        'platform' => 'ruby'
      }
      
      add_context_lines(frame, file, lineno) if File.exist?(file)
      
      frame
    end

    def self.is_gem_path?(path)
      path.include?('/gems/') || 
      path.include?('/ruby/') ||
      path.include?('/.rbenv/') ||
      path.include?('/.rvm/')
    end
    
    def self.add_context_lines(frame, file_path, lineno, context_size = 5)
      begin
        lines = File.readlines(file_path)
        return if lines.empty?
        
        return unless lineno > 0 && lineno <= lines.length
        
        pre_context_start = [lineno - context_size, 1].max
        post_context_end = [lineno + context_size, lines.length].min
        
        frame['context_line'] = lines[lineno - 1].chomp
        
        if pre_context_start < lineno
          frame['pre_context'] = lines[(pre_context_start - 1)...(lineno - 1)].map(&:chomp)
        end
        
        if post_context_end > lineno
          frame['post_context'] = lines[lineno...(post_context_end)].map(&:chomp)
        end
      rescue => e
        # Silently ignore file read errors
      end
    end
  end
end