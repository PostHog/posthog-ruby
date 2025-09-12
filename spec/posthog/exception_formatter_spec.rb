# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe ExceptionFormatter do
    let(:exception) do
      begin
        raise ArgumentError, "Something went wrong with ID 12345"
      rescue ArgumentError => e
        e
      end
    end

    let(:complex_exception) do
      begin
        begin
          raise StandardError, "Inner error"
        rescue StandardError
          raise ArgumentError, "Outer error"
        end
      rescue ArgumentError => e
        e
      end
    end

    describe '.format_exception' do
      it 'formats a basic exception correctly' do
        result = ExceptionFormatter.format_exception(exception)

        expect(result).to be_a(Hash)
        expect(result[:type]).to eq('ArgumentError')
        expect(result[:value]).to eq('Something went wrong with ID 12345')
        expect(result[:mechanism]).to eq({
          handled: true,
          synthetic: false,
          type: 'generic'
        })
        expect(result[:stacktrace]).to be_a(Hash)
        expect(result[:stacktrace][:type]).to eq('resolved')
        expect(result[:stacktrace][:frames]).to be_an(Array)
      end

      it 'handles exceptions with custom options' do
        result = ExceptionFormatter.format_exception(exception, {
          handled: false,
          mechanism_type: 'middleware'
        })

        expect(result[:mechanism]).to eq({
          handled: false,
          synthetic: false,
          type: 'middleware'
        })
      end

      it 'handles exceptions without backtrace' do
        exception_without_backtrace = RuntimeError.new("Test error")
        result = ExceptionFormatter.format_exception(exception_without_backtrace)

        expect(result[:stacktrace][:frames]).to eq([])
      end
    end

    describe '.generate_fingerprint' do
      it 'generates a consistent fingerprint for the same exception' do
        fingerprint1 = ExceptionFormatter.generate_fingerprint(exception)
        fingerprint2 = ExceptionFormatter.generate_fingerprint(exception)

        expect(fingerprint1).to eq(fingerprint2)
        expect(fingerprint1).to be_a(String)
        expect(fingerprint1.length).to eq(64) # SHA256 hex length
      end

      it 'uses custom fingerprint when provided' do
        custom_fingerprint = 'custom_error_group_123'
        result = ExceptionFormatter.generate_fingerprint(exception, custom_fingerprint)

        expect(result).to eq(custom_fingerprint)
      end

      it 'normalizes messages for consistent fingerprinting' do
        error1 = RuntimeError.new("Error with ID 123 at 2023-01-01T10:00:00")
        error2 = RuntimeError.new("Error with ID 456 at 2023-01-02T15:30:45")

        # Stub the backtrace to be the same
        allow(error1).to receive(:backtrace).and_return(["/app/test.rb:10:in 'method'"])
        allow(error2).to receive(:backtrace).and_return(["/app/test.rb:10:in 'method'"])

        fingerprint1 = ExceptionFormatter.generate_fingerprint(error1)
        fingerprint2 = ExceptionFormatter.generate_fingerprint(error2)

        expect(fingerprint1).to eq(fingerprint2)
      end

      it 'generates different fingerprints for different exception types' do
        error1 = ArgumentError.new("Test error")
        error2 = StandardError.new("Test error")

        fingerprint1 = ExceptionFormatter.generate_fingerprint(error1)
        fingerprint2 = ExceptionFormatter.generate_fingerprint(error2)

        expect(fingerprint1).not_to eq(fingerprint2)
      end
    end

    describe 'stacktrace formatting' do
      it 'formats stacktrace frames correctly' do
        result = ExceptionFormatter.format_exception(exception)
        frames = result[:stacktrace][:frames]

        expect(frames).to be_an(Array)
        frames.each do |frame|
          expect(frame).to have_key(:filename)
          expect(frame).to have_key(:lineno)
          expect(frame).to have_key(:function)
          expect(frame).to have_key(:in_app)
          expect(frame).to have_key(:raw_id)
          expect(frame).to have_key(:resolved)
          expect(frame).to have_key(:lang)

          expect(frame[:resolved]).to be true
          expect(frame[:lang]).to eq('ruby')
          expect(frame[:lineno]).to be_a(Integer)
          expect(frame[:raw_id]).to be_a(String)
          expect([true, false]).to include(frame[:in_app])
        end
      end

      it 'correctly identifies application vs library code' do
        # Create an exception with a known stack trace
        allow(exception).to receive(:backtrace).and_return([
          "/app/models/user.rb:25:in 'find_user'",
          "/gems/activerecord-7.0.0/lib/active_record.rb:100:in 'find'",
          "/usr/local/lib/ruby/3.0.0/uri.rb:50:in 'parse'"
        ])

        result = ExceptionFormatter.format_exception(exception)
        frames = result[:stacktrace][:frames]

        # Application code should be marked as in_app: true
        app_frame = frames.find { |f| f[:filename].include?('/app/models/user.rb') }
        expect(app_frame[:in_app]).to be true

        # Gem code should be marked as in_app: false  
        gem_frame = frames.find { |f| f[:filename].include?('/gems/') }
        expect(gem_frame[:in_app]).to be false

        # Ruby standard library should be marked as in_app: false
        ruby_frame = frames.find { |f| f[:filename].include?('/ruby/') }
        expect(ruby_frame[:in_app]).to be false
      end

      it 'handles malformed backtrace lines gracefully' do
        allow(exception).to receive(:backtrace).and_return([
          "/app/test.rb:10:in 'method'",
          "malformed line without colons",
          "",
          nil
        ].compact)

        result = ExceptionFormatter.format_exception(exception)
        frames = result[:stacktrace][:frames]

        # Should only include parseable frames
        expect(frames.length).to eq(1)
        expect(frames.first[:filename]).to eq('/app/test.rb')
      end
    end

    describe 'message normalization' do
      it 'normalizes timestamps in error messages' do
        normalized = ExceptionFormatter.send(:normalized_message, 
          "Error occurred at 2023-01-01T10:00:00")
        expect(normalized).to eq("Error occurred at <TIMESTAMP>")
      end

      it 'normalizes numeric IDs' do
        normalized = ExceptionFormatter.send(:normalized_message, 
          "User 12345 not found")
        expect(normalized).to eq("User <NUMBER> not found")
      end

      it 'normalizes hex addresses' do
        normalized = ExceptionFormatter.send(:normalized_message, 
          "Memory address 0x7fff5fbff710")
        expect(normalized).to eq("Memory address <HEX>")
      end

      it 'normalizes UUIDs' do
        normalized = ExceptionFormatter.send(:normalized_message, 
          "Request a1b2c3d4-e5f6-7890-abcd-ef1234567890 failed")
        expect(normalized).to eq("Request <UUID> failed")
      end
    end
  end
end