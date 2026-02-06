# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Layout/LineLength

module PostHog
  describe ExceptionCapture do
    describe '#parse_backtrace_line' do
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

      it 'does not add context lines for non-in_app frames' do
        # Use a gem-style path that points to this real file so File.exist? would be true
        # but in_app should be false, so context lines should not be added
        gem_line = "#{__FILE__}:10:in `gem_method'"
          .gsub(%r{/spec/}, '/gems/ruby/spec/')
        frame = described_class.parse_backtrace_line(gem_line)

        expect(frame['in_app']).to be false
        expect(frame['context_line']).to be_nil
        expect(frame['pre_context']).to be_nil
        expect(frame['post_context']).to be_nil
      end

      it 'adds context lines for in_app frames' do
        # Use a real in_app path so File.exist? is true and in_app is true
        app_line = "#{__FILE__}:10:in `app_method'"
        frame = described_class.parse_backtrace_line(app_line)

        expect(frame['in_app']).to be true
        expect(frame['context_line']).not_to be_nil
      end
    end

    describe '#add_context_lines' do
      it 'adds context lines from real exception' do
        def test_method_that_throws
          # -5
          # -4
          # -3
          # -2
          # -1
          raise StandardError, 'Test exception for context'
          # +1
          # +2
          # +3
          # +4
          # +5
        end

        begin
          test_method_that_throws
        rescue StandardError => e
          backtrace_line = e.backtrace.first

          frame = described_class.parse_backtrace_line(backtrace_line)
          expect(frame).not_to be_nil

          described_class.add_context_lines(frame, frame['abs_path'], frame['lineno'])

          expect(frame['context_line']).to include('raise StandardError')

          expect(frame['pre_context']).to be_an(Array)
          expect(frame['pre_context'].length).to eq(5)
          expect(frame['pre_context'][0]).to include('# -5')
          expect(frame['pre_context'][1]).to include('# -4')
          expect(frame['pre_context'][2]).to include('# -3')
          expect(frame['pre_context'][3]).to include('# -2')
          expect(frame['pre_context'][4]).to include('# -1')

          expect(frame['post_context']).to be_an(Array)
          expect(frame['post_context'].length).to eq(5)
          expect(frame['post_context'][0]).to include('# +1')
          expect(frame['post_context'][1]).to include('# +2')
          expect(frame['post_context'][2]).to include('# +3')
          expect(frame['post_context'][3]).to include('# +4')
          expect(frame['post_context'][4]).to include('# +5')
        end
      end
    end

    describe '#build_stacktrace' do
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

    describe '#build_parsed_exception' do
      it 'builds exception info from string' do
        exception_info = described_class.build_parsed_exception('Simple error')

        expect(exception_info['type']).to eq('Error')
        expect(exception_info['value']).to eq('Simple error')
        expect(exception_info['mechanism']['type']).to eq('generic')
        expect(exception_info['mechanism']['handled']).to be true
        expect(exception_info['stacktrace']).to be_nil
      end

      it 'builds exception info from exception object' do
        raise StandardError, 'Test exception'
      rescue StandardError => e
        exception_info = described_class.build_parsed_exception(e)

        expect(exception_info['type']).to eq('StandardError')
        expect(exception_info['value']).to eq('Test exception')
        expect(exception_info['mechanism']['type']).to eq('generic')
        expect(exception_info['mechanism']['handled']).to be true
        expect(exception_info['stacktrace']).not_to be_nil
        expect(exception_info['stacktrace']['type']).to eq('raw')
      end

      it 'builds exception info from exception-like objects' do
        exception_like = Object.new
        def exception_like.message
          'Custom error message'
        end

        def exception_like.backtrace
          ['line1.rb:10:in method', 'line2.rb:20:in another_method']
        end

        exception_info = described_class.build_parsed_exception(exception_like)

        expect(exception_info['type']).to eq('Object')
        expect(exception_info['value']).to eq('Custom error message')
        expect(exception_info['mechanism']['type']).to eq('generic')
        expect(exception_info['mechanism']['handled']).to be true
        expect(exception_info['stacktrace']).not_to be_nil
        expect(exception_info['stacktrace']['frames']).to be_an(Array)
      end

      it 'returns nil for invalid input types' do
        expect(described_class.build_parsed_exception({ invalid: 'object' })).to be_nil
        expect(described_class.build_parsed_exception(123)).to be_nil
        expect(described_class.build_parsed_exception(nil)).to be_nil
      end
    end
  end
end
# rubocop:enable Layout/LineLength
