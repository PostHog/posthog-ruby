# frozen_string_literal: true

require 'rails/generators'

module Posthog
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      desc 'Creates a PostHog initializer file at config/initializers/posthog.rb'

      source_root File.expand_path('../../..', __dir__)

      def copy_initializer
        copy_file 'examples/posthog.rb', 'config/initializers/posthog.rb'
      end

      def show_readme
        say ''
        say 'PostHog Rails has been installed!', :green
        say ''
        say 'Next steps:', :yellow
        say '  1. Edit config/initializers/posthog.rb with your PostHog API key'
        say '  2. Set environment variables:'
        say '     - POSTHOG_API_KEY (required)'
        say '     - POSTHOG_PERSONAL_API_KEY (optional, for feature flags)'
        say ''
        say 'For more information, see: https://posthog.com/docs/libraries/ruby'
        say ''
      end
    end
  end
end
