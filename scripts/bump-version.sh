#!/usr/bin/env bash
set -euo pipefail

ruby <<'RUBY'
require 'json'

updates = {
  'lib/posthog/version.rb' => JSON.parse(File.read('posthog-ruby/package.json')).fetch('version'),
  'posthog-rails/lib/posthog/rails/version.rb' => JSON.parse(File.read('posthog-rails/package.json')).fetch('version')
}

updates.each do |path, version|
  contents = File.read(path)
  unless contents.match?(/VERSION = '[^']+'/)
    raise "Could not find VERSION constant in #{path}"
  end

  updated = contents.sub(/VERSION = '[^']+'/, "VERSION = '#{version}'")
  File.write(path, updated)
end
RUBY
