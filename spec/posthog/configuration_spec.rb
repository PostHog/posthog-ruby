# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe Configuration do
    let(:config) { Configuration.new }

    describe '#initialize' do
      it 'sets default values' do
        expect(config.api_key).to be_nil
        expect(config.host).to eq('https://app.posthog.com')
        expect(config.auto_capture_exceptions).to be false
        expect(config.ignored_exceptions).to be_an(Array)
        expect(config.max_queue_size).to eq(10_000)
      end

      it 'includes sensible default ignored exceptions' do
        expect(config.ignored_exceptions).to include('ActionController::RoutingError')
        expect(config.ignored_exceptions).to include('SignalException')
      end
    end

    describe '#api_key=' do
      it 'enables auto_capture_exceptions when API key is set' do
        config.api_key = 'test_key'
        expect(config.auto_capture_exceptions).to be true
      end

      it 'does not override explicit auto_capture_exceptions setting' do
        config.auto_capture_exceptions = false
        config.api_key = 'test_key'
        expect(config.auto_capture_exceptions).to be false
      end
    end

    describe '#configured?' do
      it 'returns false when no API key is set' do
        expect(config.configured?).to be false
      end

      it 'returns false when API key is empty' do
        config.api_key = ''
        expect(config.configured?).to be false
      end

      it 'returns true when API key is set' do
        config.api_key = 'test_key'
        expect(config.configured?).to be true
      end
    end

    describe '#validate!' do
      it 'raises error when API key is not set' do
        expect { config.validate! }.to raise_error(ArgumentError, 'PostHog API key is required')
      end

      it 'raises error when ignored_exceptions is not an array' do
        config.api_key = 'test_key'
        config.auto_capture_exceptions = true
        config.ignored_exceptions = 'not_an_array'
        
        expect { config.validate! }.to raise_error(ArgumentError, 'ignored_exceptions must be an Array')
      end

      it 'raises error when ignored_exceptions contains invalid types' do
        config.api_key = 'test_key'
        config.auto_capture_exceptions = true
        config.ignored_exceptions = [123]
        
        expect { config.validate! }.to raise_error(ArgumentError, 'ignored_exceptions must contain String, Class, or Regexp objects')
      end

      it 'accepts valid ignored_exceptions types' do
        config.api_key = 'test_key'
        config.auto_capture_exceptions = true
        config.ignored_exceptions = ['String', StandardError, /regex/]
        
        expect { config.validate! }.not_to raise_error
      end

      it 'validates default_distinct_id_strategy' do
        config.api_key = 'test_key'
        config.default_distinct_id_strategy = :invalid
        
        expect { config.validate! }.to raise_error(ArgumentError, 'default_distinct_id_strategy must be :ip_address, :anonymous, or :session')
      end
    end
  end

  describe 'global configuration' do
    before { PostHog.reset! }
    after { PostHog.reset! }

    describe '.configure' do
      it 'yields configuration object' do
        PostHog.configure do |config|
          expect(config).to be_a(Configuration)
          config.api_key = 'test_key'
        end
        
        expect(PostHog.configuration.api_key).to eq('test_key')
      end

      it 'validates configuration after block' do
        expect do
          PostHog.configure do |config|
            config.api_key = nil
          end
        end.to raise_error(ArgumentError, 'PostHog API key is required')
      end

      it 'initializes global client' do
        PostHog.configure do |config|
          config.api_key = 'test_key'
          config.test_mode = true
        end
        
        expect(PostHog.client).to be_a(Client)
      end
    end

    describe '.configured?' do
      it 'returns false when not configured' do
        expect(PostHog.configured?).to be false
      end

      it 'returns true when configured' do
        PostHog.configuration.api_key = 'test_key'
        expect(PostHog.configured?).to be true
      end
    end

    describe 'convenience methods' do
      let(:client) { instance_double(Client) }
      
      before do
        PostHog.configuration.api_key = 'test_key'
        allow(PostHog).to receive(:client).and_return(client)
      end

      describe '.capture_exception' do
        it 'delegates to client when configured' do
          exception = StandardError.new('test')
          attrs = { distinct_id: 'user_123' }
          
          expect(client).to receive(:capture_exception).with(exception, attrs)
          PostHog.capture_exception(exception, attrs)
        end

        it 'does nothing when not configured' do
          PostHog.configuration.api_key = nil
          
          expect(client).not_to receive(:capture_exception)
          PostHog.capture_exception(StandardError.new('test'))
        end
      end

      describe '.capture' do
        it 'delegates to client when configured' do
          attrs = { distinct_id: 'user_123', event: 'test_event' }
          
          expect(client).to receive(:capture).with(attrs)
          PostHog.capture(attrs)
        end
      end

      describe '.identify' do
        it 'delegates to client when configured' do
          attrs = { distinct_id: 'user_123', properties: { name: 'Test User' } }
          
          expect(client).to receive(:identify).with(attrs)
          PostHog.identify(attrs)
        end
      end
    end
  end
end