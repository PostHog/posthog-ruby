# frozen_string_literal: true

require_relative 'scripts/public_api_snapshot'

namespace :public_api do
  desc 'Generate the public API snapshot'
  task :generate do
    PublicApiSnapshot.write
  end

  desc 'Check that the public API snapshot matches the current code'
  task :check do
    exit 1 unless PublicApiSnapshot.check
  end
end
