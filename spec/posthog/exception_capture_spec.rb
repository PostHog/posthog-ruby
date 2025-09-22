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
        # Define a method that will throw an exception with more context
        def test_method_that_throws
          # Line 1 before exception
          puts "First line before exception"
          # Line 2 before exception  
          puts "Second line before exception"
          # Line 3 before exception
          variable_before = "some setup"
          # Line 4 before exception
          puts "Fourth line before exception"
          # Line 5 before exception - this will be the last pre_context line
          puts "Fifth line before exception"
          raise StandardError, 'Test exception for context'  # This line will be the context_line
          # Line 1 after exception (unreachable)
          puts "First line after exception"
          # Line 2 after exception (unreachable)
          puts "Second line after exception"  
          # Line 3 after exception (unreachable)
          puts "Third line after exception"
          # Line 4 after exception (unreachable)
          puts "Fourth line after exception"
          # Line 5 after exception (unreachable)
          puts "Fifth line after exception"
        end
        
        begin
          test_method_that_throws
        rescue => e
          # Get the first frame from this file (not from gems)
          backtrace_line = e.backtrace.find { |line| line.include?(__FILE__) }
          
          # Parse the backtrace line to get file and line number
          frame = described_class.parse_backtrace_line(backtrace_line)
          expect(frame).not_to be_nil
          
          # Test adding context lines with default context size (5 lines before/after)
          described_class.add_context_lines(frame, frame['abs_path'], frame['lineno'])
          
          
          # Verify the context line (the actual exception line)
          expect(frame['context_line']).to include('raise StandardError')
          
          # Verify pre_context has the correct lines (the 5 lines immediately before)
          expect(frame['pre_context']).to be_an(Array)
          expect(frame['pre_context'].length).to eq(5)
          expect(frame['pre_context'][0]).to include('variable_before = "some setup"')  # Line 1
          expect(frame['pre_context'][1]).to include('# Line 4 before exception')      # Line 2
          expect(frame['pre_context'][2]).to include('puts "Fourth line before exception"') # Line 3
          expect(frame['pre_context'][3]).to include('# Line 5 before exception')      # Line 4  
          expect(frame['pre_context'][4]).to include('puts "Fifth line before exception"') # Line 5
          
          # Verify post_context has lines after the exception  
          expect(frame['post_context']).to be_an(Array)
          expect(frame['post_context'].length).to eq(5)
          expect(frame['post_context'][0]).to include('# Line 1 after exception')     # Line 1
          expect(frame['post_context'][1]).to include('puts "First line after exception"') # Line 2
          expect(frame['post_context'][2]).to include('# Line 2 after exception')     # Line 3
          expect(frame['post_context'][3]).to include('puts "Second line after exception"') # Line 4
          expect(frame['post_context'][4]).to include('# Line 3 after exception')     # Line 5
          
          # Test with custom context size (2 lines)
          frame_small = described_class.parse_backtrace_line(backtrace_line)
          described_class.add_context_lines(frame_small, frame_small['abs_path'], frame_small['lineno'], 2)
          
          
          expect(frame_small['pre_context'].length).to eq(2)
          expect(frame_small['post_context'].length).to eq(2)
          expect(frame_small['pre_context'][0]).to include('# Line 5 before exception')
          expect(frame_small['pre_context'][1]).to include('puts "Fifth line before exception"')
          expect(frame_small['post_context'][0]).to include('# Line 1 after exception')
          expect(frame_small['post_context'][1]).to include('puts "First line after exception"')
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
