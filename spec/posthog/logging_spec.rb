# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe Logging do
    describe '.logger default' do
      {
        'without Rails' => -> { hide_const('Rails') },
        # rails-html-sanitizer defines ::Rails without railties.
        'with a Rails module that has no logger' => -> { stub_const('Rails', Module.new) }
      }.each do |context_name, define_rails|
        context context_name do
          before do
            instance_exec(&define_rails)
            Logging.logger = nil
          end

          it 'writes to stderr, leaving stdout to the host program' do
            expect do
              expect { Logging.logger.error('send failed') }
                .to output(/ERROR -- PostHog: \[posthog-ruby\] send failed/).to_stderr
            end.not_to output.to_stdout
          end
        end
      end
    end

    describe '.logger default under Rails' do
      let(:rails) { Module.new { singleton_class.attr_accessor :logger } }

      before do
        stub_const('Rails', rails)
        Logging.logger = nil
      end

      it 'writes to stderr until Rails.logger exists, then to Rails.logger' do
        expect { Logging.logger.error('before boot') }
          .to output(/ERROR -- PostHog: \[posthog-ruby\] before boot/).to_stderr

        rails_log = StringIO.new
        rails.logger = Logger.new(rails_log)

        expect { Logging.logger.error('after boot') }.not_to output.to_stderr
        expect(rails_log.string).to include('[posthog-ruby] after boot')
      end
    end
  end
end
