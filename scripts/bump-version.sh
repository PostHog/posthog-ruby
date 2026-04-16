#!/usr/bin/env bash
set -euo pipefail

NEW_VERSION="${1:?usage: scripts/bump-version.sh <version>}"
export NEW_VERSION

ruby <<'RUBY'
path = 'lib/posthog/version.rb'
new_version = ENV.fetch('NEW_VERSION')
contents = File.read(path)
updated = contents.sub(/VERSION = '[^']+'/, "VERSION = '#{new_version}'")
raise 'Could not find VERSION constant in lib/posthog/version.rb' if updated == contents
File.write(path, updated)
RUBY
