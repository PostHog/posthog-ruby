# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe ExceptionCapture do
    describe '.parse_backtrace_line' do
      it 'parses stacktrace line into frame with correct details' do
        line = '/path/to/project/app/models/user.rb:42:in `validate_email\''
        frame = described_class.parse_backtrace_line(line)

        expect(frame['filename']).to eq('user.rb')
        expect(frame['abs_path']).to eq('/path/to/project/app/models/user.rb')
        expect(frame['lineno']).to eq(42)
        expect(frame['function']).to eq('validate_email')
        expect(frame['platform']).to eq('ruby')
        expect(frame['in_app']).to be true
      end

      it 'identifies gem files correctly' do
        gem_line = '/path/to/gems/ruby-3.0.0/lib/ruby/gems/3.0.0/gems/some_gem/lib/some_gem.rb:10:in `gem_method\''
        frame = described_class.parse_backtrace_line(gem_line)

        expect(frame['in_app']).to be false
      end
    end

    describe '.add_context_lines' do
      it 'adds context lines from real exception' do
        # Define a method that will throw an exception
        def test_method_that_throws
          puts "Line before exception"
          raise StandardError, 'Test exception for context'  # This line will be the context_line
          puts "Line after exception (unreachable)"
        end
        
        begin
          test_method_that_throws
        rescue => e
          # Get the first frame from this file (not from gems)
          backtrace_line = e.backtrace.find { |line| line.include?(__FILE__) }
          
          # Parse the backtrace line to get file and line number
          frame = described_class.parse_backtrace_line(backtrace_line)
          expect(frame).not_to be_nil
          
          # Now test adding context lines from the real source file
          described_class.add_context_lines(frame, frame['abs_path'], frame['lineno'])
          
          # Verify that context lines were added
          expect(frame['context_line']).to include('raise StandardError')
          expect(frame['pre_context']).to be_an(Array)
          expect(frame['post_context']).to be_an(Array)
          
          # The line before should contain our comment or code
          expect(frame['pre_context'].last).to include('puts "Line before exception"')
        end
      end
    end

    describe '.build_stacktrace' do
      it 'converts backtrace array to structured frames' do
        backtrace = [
          '/path/to/project/app/models/user.rb:42:in `validate_email\'',
          '/path/to/gems/ruby-3.0.0/lib/ruby/gems/3.0.0/gems/actionpack-7.0.0/lib/action_controller.rb:123:in `dispatch\''
        ]
        
        stacktrace = described_class.build_stacktrace(backtrace)
        
        expect(stacktrace['type']).to eq('raw')
        expect(stacktrace['frames'].length).to eq(2)
        
        expect(stacktrace['frames'][0]['filename']).to eq('action_controller.rb')
        expect(stacktrace['frames'][1]['filename']).to eq('user.rb')
      end
    end

    describe '.build_exception_properties' do
      it 'creates structured exception data' do
        begin
          raise StandardError, 'Test error message'
        rescue => e
          properties = described_class.build_exception_properties(e)
          
          expect(properties['$exception_type']).to eq('StandardError')
          expect(properties['$exception_value']).to eq('Test error message')
          expect(properties['$exception_list']).to be_an(Array)
          expect(properties['$exception_list'].first['stacktrace']['type']).to eq('raw')
        end
      end
    end
  end
end
