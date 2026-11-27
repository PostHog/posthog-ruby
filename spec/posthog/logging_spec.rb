# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe Logging do
    describe '.logger default' do
      before do
        hide_const('Rails')
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
