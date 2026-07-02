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
        gem_file = File.join(Gem.path.first, 'gems', 'some_gem-1.0.0', 'lib', 'some_gem.rb')
        frame = described_class.parse_backtrace_line("#{gem_file}:10:in `gem_method'")

        expect(frame['in_app']).to be false
      end

      it 'identifies standard library files correctly' do
        stdlib_file = File.join(RbConfig::CONFIG['rubylibdir'], 'json.rb')
        frame = described_class.parse_backtrace_line("#{stdlib_file}:10:in `parse'")

        expect(frame['in_app']).to be false
      end

      it 'does not add context lines for non-in_app frames' do
        # Use a real file from a loaded gem so File.exist? is true
        # but in_app is false, so context lines should not be added
        gem_file = File.join(Gem.loaded_specs['rspec-core'].full_gem_path, 'lib', 'rspec', 'core.rb')
        expect(File.exist?(gem_file)).to be true

        frame = described_class.parse_backtrace_line("#{gem_file}:10:in `gem_method'")

        expect(frame['in_app']).to be false
        expect(frame['context_line']).to be_nil
        expect(frame['pre_context']).to be_nil
        expect(frame['post_context']).to be_nil
      end

      it 'uses project-relative filenames for paths inside the project root' do
        line = '/app/releases/20240101/app/models/user.rb:42:in `validate_email\''
        frame = described_class.parse_backtrace_line(line, project_root: '/app/releases/20240101')

        expect(frame['filename']).to eq('app/models/user.rb')
        expect(frame['abs_path']).to eq('/app/releases/20240101/app/models/user.rb')
      end

      it 'falls back to the basename for paths outside the project root' do
        line = '/somewhere/else/app/models/user.rb:42:in `validate_email\''
        frame = described_class.parse_backtrace_line(line, project_root: '/app/releases/20240101')

        expect(frame['filename']).to eq('user.rb')
        expect(frame['abs_path']).to eq('/somewhere/else/app/models/user.rb')
      end

      it 'derives filenames for real project files relative to the current working directory' do
        frame = described_class.parse_backtrace_line("#{File.expand_path(__FILE__)}:10:in `app_method'")

        expect(frame['filename']).to eq('spec/posthog/exception_capture_spec.rb')
        expect(frame['abs_path']).to eq(File.expand_path(__FILE__))
        expect(frame['in_app']).to be true
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

      it 'computes dependency roots once for all frames' do
        backtrace = [
          '/app/app/models/user.rb:42:in `validate_email\'',
          '/app/app/controllers/users_controller.rb:10:in `show\''
        ]

        expect(described_class).to receive(:dependency_roots).once.and_return([])

        stacktrace = described_class.build_stacktrace(backtrace)

        expect(stacktrace['frames'].length).to eq(2)
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

      it 'applies a custom mechanism' do
        exception_info = described_class.build_parsed_exception(
          'Simple error',
          mechanism: { 'type' => 'rails', 'handled' => false }
        )

        expect(exception_info['mechanism']['type']).to eq('rails')
        expect(exception_info['mechanism']['handled']).to be false
      end
    end

    describe '#build_exception_list' do
      # Exception-like object with a configurable cause, used to build chains
      # without raising for real.
      let(:chainable_class) do
        Class.new do
          attr_accessor :cause

          def initialize(message)
            @message = message
          end

          attr_reader :message

          def backtrace
            nil
          end
        end
      end

      def raise_chained
        begin
          raise ArgumentError, 'Root cause'
        rescue ArgumentError
          raise 'Middle error'
        end
      rescue RuntimeError
        raise StandardError, 'Wrapper error'
      end

      it 'builds a single-element list for an exception without a cause' do
        raise StandardError, 'Test exception'
      rescue StandardError => e
        exception_list = described_class.build_exception_list(e)

        expect(exception_list.length).to eq(1)
        expect(exception_list.first['type']).to eq('StandardError')
        expect(exception_list.first['mechanism']).to eq(
          'type' => 'generic',
          'handled' => true,
          'exception_id' => 0
        )
      end

      it 'walks the cause chain outermost-first' do
        raise_chained
      rescue StandardError => e
        exception_list = described_class.build_exception_list(e)

        expect(exception_list.map { |entry| entry['type'] }).to eq(%w[StandardError RuntimeError ArgumentError])
        expect(exception_list.map { |entry| entry['value'] }).to eq(['Wrapper error', 'Middle error', 'Root cause'])
      end

      it 'tags chained causes with a chained mechanism and parent linkage' do
        raise_chained
      rescue StandardError => e
        exception_list = described_class.build_exception_list(e)

        expect(exception_list[0]['mechanism']).to eq(
          'type' => 'generic',
          'handled' => true,
          'exception_id' => 0
        )
        expect(exception_list[1]['mechanism']).to eq(
          'type' => 'chained',
          'handled' => true,
          'source' => 'cause',
          'exception_id' => 1,
          'parent_id' => 0
        )
        expect(exception_list[2]['mechanism']).to eq(
          'type' => 'chained',
          'handled' => true,
          'source' => 'cause',
          'exception_id' => 2,
          'parent_id' => 1
        )
      end

      it 'threads a custom mechanism through the chain' do
        raise_chained
      rescue StandardError => e
        exception_list = described_class.build_exception_list(e, mechanism: { 'type' => 'rails', 'handled' => false })

        expect(exception_list[0]['mechanism']['type']).to eq('rails')
        expect(exception_list[0]['mechanism']['handled']).to be false
        expect(exception_list[1]['mechanism']['type']).to eq('chained')
        expect(exception_list[1]['mechanism']['handled']).to be false
      end

      it 'guards against cycles in the cause chain' do
        first = chainable_class.new('first')
        second = chainable_class.new('second')
        first.cause = second
        second.cause = first

        exception_list = described_class.build_exception_list(first)

        expect(exception_list.map { |entry| entry['value'] }).to eq(%w[first second])
      end

      it 'caps the cause chain depth' do
        outermost = chainable_class.new('error 0')
        current = outermost
        1.upto(59) do |i|
          cause = chainable_class.new("error #{i}")
          current.cause = cause
          current = cause
        end

        exception_list = described_class.build_exception_list(outermost)

        expect(exception_list.length).to eq(described_class::MAX_CHAINED_EXCEPTIONS)
        expect(exception_list.last['value']).to eq('error 49')
      end

      it 'builds a single-element list for strings' do
        exception_list = described_class.build_exception_list('Simple error')

        expect(exception_list.length).to eq(1)
        expect(exception_list.first['value']).to eq('Simple error')
      end

      it 'returns nil for invalid input types' do
        expect(described_class.build_exception_list({ invalid: 'object' })).to be_nil
        expect(described_class.build_exception_list(123)).to be_nil
        expect(described_class.build_exception_list(nil)).to be_nil
      end
    end
  end
end
# rubocop:enable Layout/LineLength
