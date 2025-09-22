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

    describe '#build_exception_properties' do
      it 'creates structured exception data' do
        raise StandardError, 'Test error message'
      rescue StandardError => e
        properties = described_class.build_exception_properties(e)

        expect(properties['$exception_list']).to be_an(Array)
        expect(properties['$exception_list'].first['type']).to eq('StandardError')
        expect(properties['$exception_list'].first['value']).to eq('Test error message')
        expect(properties['$exception_list'].first['stacktrace']['type']).to eq('raw')
      end
    end
  end

end
# rubocop:enable Layout/LineLength
