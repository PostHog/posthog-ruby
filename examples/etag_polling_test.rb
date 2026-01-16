#!/usr/bin/env ruby
# frozen_string_literal: true

# ETag Polling Test Script
#
# Tests ETag support for local evaluation polling by polling every 5 seconds
# and logging the stored flags and ETag behavior.
#
# NOTE: This script accesses internal/private fields (@flags_etag, @feature_flags)
# for debugging purposes. These are not part of the public API and may change
# or break in future versions.
#
# Usage:
#   ruby examples/etag_polling_test.rb
#
# Create a .env file with:
#   POSTHOG_PROJECT_API_KEY=your_project_api_key
#   POSTHOG_PERSONAL_API_KEY=your_personal_api_key
#   POSTHOG_HOST=https://us.posthog.com  # optional

# Import the library (use local development version)
$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'posthog'
require 'net/http'

# Load environment variables from .env file if available
def load_env_file
  env_paths = [
    File.join(File.dirname(__FILE__), '.env'),          # examples/.env
    File.join(File.dirname(__FILE__), '..', '.env'),    # repo root .env
    File.join(Dir.pwd, '.env')                          # current working directory
  ]

  env_paths.each do |env_path|
    next unless File.exist?(env_path)

    puts "Loading environment from: #{env_path}\n\n"
    File.readlines(env_path).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      key, value = line.split('=', 2)
      next unless key && value

      # Remove surrounding quotes if present
      value = value.gsub(/\A["']|["']\z/, '')
      ENV[key] = value unless ENV.key?(key)
    end
    break
  end
end

load_env_file

API_KEY = ENV['POSTHOG_PROJECT_API_KEY'] || ''
PERSONAL_API_KEY = ENV['POSTHOG_PERSONAL_API_KEY'] || ''
HOST = ENV['POSTHOG_HOST'] || 'https://us.posthog.com'
POLL_INTERVAL_SECONDS = 5

if API_KEY.empty? || PERSONAL_API_KEY.empty?
  warn 'Missing required environment variables.'
  warn ''
  warn 'Create a .env file with:'
  warn '  POSTHOG_PROJECT_API_KEY=your_project_api_key'
  warn '  POSTHOG_PERSONAL_API_KEY=your_personal_api_key'
  warn '  POSTHOG_HOST=https://us.posthog.com  # optional'
  exit 1
end

puts '=' * 60
puts 'ETag Polling Test'
puts '=' * 60
puts "Host: #{HOST}"
puts "Poll interval: #{POLL_INTERVAL_SECONDS}s"
puts '=' * 60
puts ''

# Create PostHog client with local evaluation enabled
posthog = PostHog::Client.new(
  api_key: API_KEY,
  personal_api_key: PERSONAL_API_KEY,
  host: HOST,
  feature_flags_polling_interval: POLL_INTERVAL_SECONDS,
  on_error: proc { |status, msg| puts "Error (#{status}): #{msg}" }
)

# Access the internal poller for debugging
poller = posthog.instance_variable_get(:@feature_flags_poller)

# Enable debug logging to see ETag behavior
posthog.logger.level = Logger::DEBUG

def log_flags(poller)
  flags = poller.instance_variable_get(:@feature_flags) || []
  etag_ref = poller.instance_variable_get(:@flags_etag)
  etag = etag_ref&.value

  puts '-' * 40
  puts "Stored ETag: #{etag || '(none)'}"
  puts "Flag count: #{flags.length}"

  if flags.length.positive?
    puts 'Flags:'
    flags.first(10).each do |flag|
      puts "  - #{flag[:key]} (active: #{flag[:active]})"
    end
    puts "  ... and #{flags.length - 10} more" if flags.length > 10
  end
  puts '-' * 40
  puts ''
end

puts 'Waiting for initial flag load...'
puts ''

# Wait for initial load
sleep 1
log_flags(poller)

# Set up graceful shutdown
running = true
Signal.trap('INT') do
  puts "\nShutting down..."
  running = false
end

puts 'Press Ctrl+C to stop'
puts ''
puts 'Polling every 5 seconds. Watch for 304 Not Modified responses...'
puts ''

# Poll and log periodically
while running
  sleep POLL_INTERVAL_SECONDS + 1 # Offset to log after each poll
  break unless running

  log_flags(poller)
end

posthog.shutdown
puts 'Done!'
