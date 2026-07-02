# frozen_string_literal: true

# PostHog Ruby library example
#
# This script demonstrates various PostHog Ruby SDK capabilities including:
# - Basic event capture and user identification
# - Feature flag local evaluation
# - Complex cohort evaluation (NEW!)
# - Feature flag payloads
#
# Setup:
# 1. Copy .env.example to .env and fill in your PostHog credentials
# 2. For complex cohort examples, create the required cohort and feature flag
#    (see option 3 in the menu for detailed setup instructions)

# Import the library (use local development version)
$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), 'lib'))
require 'posthog'

# Load environment variables from .env file if available
begin
  require 'dotenv/load'
rescue LoadError
  # dotenv not available, load .env manually if it exists
  env_file = File.join(File.dirname(__FILE__), '.env')
  if File.exist?(env_file)
    File.readlines(env_file).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      key, value = line.split('=', 2)
      ENV[key] = value if key && value && !ENV.key?(key)
    end
  end
end

# Get configuration
api_key = ENV['POSTHOG_PROJECT_API_KEY'] || ''
personal_api_key = ENV['POSTHOG_PERSONAL_API_KEY'] || ''
host = ENV['POSTHOG_HOST'] || 'http://localhost:8000'

# Check if credentials are provided
if api_key.empty? || personal_api_key.empty?
  puts '❌ Missing PostHog credentials!'
  puts '   Please set POSTHOG_PROJECT_API_KEY and POSTHOG_PERSONAL_API_KEY environment variables'
  puts '   or copy .env.example to .env and fill in your values'
  exit 1
end

# Test authentication before proceeding
puts '🔑 Testing PostHog authentication...'

begin
  # Create a minimal client for testing
  test_client = PostHog::Client.new(
    api_key: api_key,
    secret_key: personal_api_key,
    host: host,
    on_error: proc { |_status, _msg| }, # Suppress error output during test
    feature_flags_polling_interval: 60 # Longer interval for test
  )

  # Test by attempting to load feature flags (this validates both keys)
  test_client.instance_variable_get(:@feature_flags_poller).load_feature_flags(true)

  # If we get here without exception, credentials work
  puts '✅ Authentication successful!'
  puts "   API Key: #{api_key[0..8]}..."
  puts "   Personal API Key: #{personal_api_key[0..8]}..."
  puts "   Host: #{host}\n\n"

  test_client.shutdown
rescue StandardError => e
  puts '❌ Authentication failed!'
  puts "   Error: #{e.message}"
  puts "\n   Please check your credentials:"
  puts '   - POSTHOG_PROJECT_API_KEY: Project API key from PostHog settings'
  puts '   - POSTHOG_PERSONAL_API_KEY: Personal API key (required for local evaluation)'
  puts '   - POSTHOG_HOST: Your PostHog instance URL'
  exit 1
end

posthog = PostHog::Client.new(
  api_key: api_key, # You can find this key on the /setup page in PostHog
  secret_key: personal_api_key, # Required for local feature flag evaluation (Personal or Project Secret API Key)
  host: host, # Where you host PostHog. You can remove this line if using app.posthog.com
  on_error: proc { |_status, msg| print msg },
  feature_flags_polling_interval: 10 # How often to poll for feature flags
)

# Set up logging level (quieter by default)
posthog.logger.level = Logger::WARN

# Display menu and get user choice
puts "🚀 PostHog Ruby SDK Demo - Choose an example to run:\n\n"
puts '1. Identify and capture examples'
puts '2. Feature flag local evaluation examples'
puts '3. Complex cohort evaluation examples'
puts '4. Flag dependencies examples'
puts '5. Feature flag payload examples'
puts '6. Run all examples'
puts '7. Exit'
print "\nEnter your choice (1-7): "

choice = gets.chomp.to_i

case choice
when 1
  puts "\n#{'=' * 60}"
  puts 'IDENTIFY AND CAPTURE EXAMPLES'
  puts '=' * 60

  posthog.logger.level = Logger::DEBUG

  # Capture an event
  puts '📊 Capturing events...'
  posthog.capture({ distinct_id: 'distinct_id', event: 'event',
                    properties: { 'property1' => 'value', 'property2' => 'value' }, send_feature_flags: true })

  # Alias a previous distinct id with a new one
  puts '🔗 Creating alias...'
  posthog.alias(
    distinct_id: 'distinct_id',
    alias: 'new_distinct_id'
  )

  posthog.capture(
    distinct_id: 'new_distinct_id',
    event: 'event2',
    properties: { 'property1' => 'value', 'property2' => 'value' }
  )

  posthog.capture(
    distinct_id: 'new_distinct_id',
    event: 'event-with-groups',
    properties: {
      'property1' => 'value',
      'property2' => 'value'
    },
    groups: { 'company' => 'id:5' }
  )

  # Add properties to the person
  puts '👤 Identifying user...'
  posthog.identify(
    distinct_id: 'new_distinct_id',
    properties: { 'email' => 'something@something.com' }
  )

  # Add properties to a group
  puts '🏢 Identifying group...'
  posthog.group_identify(
    group_type: 'company',
    group_key: 'id:5',
    properties: { 'employees' => 11 }
  )

  # Properties set only once to the person
  puts '🔒 Setting properties once...'
  posthog.capture(
    distinct_id: 'new_distinct_id',
    event: 'signup',
    properties: { '$set_once' => { 'self_serve_signup' => true } }
  )

  # This will not change the property (because it was already set)
  posthog.capture(
    distinct_id: 'new_distinct_id',
    event: 'signup',
    properties: { '$set_once' => { 'self_serve_signup' => false } }
  )

  puts '🔄 Updating properties...'
  posthog.capture(
    distinct_id: 'new_distinct_id',
    event: 'signup',
    properties: { '$set' => { 'current_browser' => 'Chrome' } }
  )

  posthog.capture(
    distinct_id: 'new_distinct_id',
    event: 'signup',
    properties: { '$set' => { 'current_browser' => 'Firefox' } }
  )

when 2
  puts "\n#{'=' * 60}"
  puts 'FEATURE FLAG LOCAL EVALUATION EXAMPLES'
  puts '=' * 60

  posthog.logger.level = Logger::DEBUG

  puts '🏁 Testing basic feature flags...'
  puts "beta-feature for 'distinct_id': #{posthog.is_feature_enabled('beta-feature', 'distinct_id')}"
  puts "beta-feature for 'new_distinct_id': #{posthog.is_feature_enabled('beta-feature', 'new_distinct_id')}"
  puts "beta-feature with groups: #{posthog.is_feature_enabled('beta-feature', 'distinct_id',
                                                               groups: { 'company' => 'id:5' })}"

  puts "\n🌍 Testing location-based flags..."
  # Assume test-flag has `City Name = Sydney` as a person property set
  puts "Sydney user: #{posthog.is_feature_enabled('test-flag', 'random_id_12345',
                                                  person_properties: { '$geoip_city_name' => 'Sydney' })}"

  puts "Sydney user (local only): #{posthog.is_feature_enabled('test-flag', 'distinct_id_random_22',
                                                               person_properties: { '$geoip_city_name' => 'Sydney' },
                                                               only_evaluate_locally: true)}"

  puts "\n📋 Getting all flags..."
  puts "All flags: #{posthog.get_all_flags('distinct_id_random_22')}"
  puts "All flags (local): #{posthog.get_all_flags('distinct_id_random_22', only_evaluate_locally: true)}"
  puts "All flags with properties: #{posthog.get_all_flags('distinct_id_random_22',
                                                           person_properties: { '$geoip_city_name' => 'Sydney' },
                                                           only_evaluate_locally: true)}"

when 3
  puts "\n#{'=' * 60}"
  puts 'COMPLEX COHORT EVALUATION EXAMPLES'
  puts '=' * 60
  puts '🧩 Testing complex cohort with nested logic...'
  puts '   Cohort structure: (verified @example.com users) OR (PostHog team members)'
  puts ''
  puts "📋 Required setup (if 'test-complex-cohort-flag' doesn't exist):"
  puts "   1. Create a cohort named 'complex-cohort' with these conditions:"
  puts '      - Type: OR'
  puts "      - Group 1 (AND): email contains '@example.com' AND is_email_verified = 'true'"
  puts '      - Group 2 (OR): User belongs to another cohort with @posthog.com emails'
  puts "   2. Create feature flag 'test-complex-cohort-flag':"
  puts "      - Condition: User belongs to cohort 'complex-cohort'"
  puts '      - Rollout: 100%'
  puts ''

  posthog.logger.level = Logger::INFO

  # Test verified @example.com user (matches first AND condition)
  result1 = posthog.is_feature_enabled(
    'test-complex-cohort-flag',
    'verified_user',
    person_properties: {
      'email' => 'user@example.com',
      'is_email_verified' => 'true'
    },
    only_evaluate_locally: true
  )
  puts "✅ Verified @example.com user: #{result1}"

  # Test @posthog.com user (matches nested cohort reference)
  result2 = posthog.is_feature_enabled(
    'test-complex-cohort-flag',
    'posthog_user',
    person_properties: { 'email' => 'dev@posthog.com' },
    only_evaluate_locally: true
  )
  puts "✅ @posthog.com user: #{result2}"

  # Test regular user (should not match either condition)
  result3 = posthog.is_feature_enabled(
    'test-complex-cohort-flag',
    'regular_user',
    person_properties: { 'email' => 'user@other.com' },
    only_evaluate_locally: true
  )
  puts "❌ Regular user: #{result3}"

  puts "\n🎯 Results Summary:"
  puts "   - Complex nested cohorts evaluated locally: #{result1 || result2 ? '✅ YES' : '❌ NO'}"
  puts '   - Zero API calls needed: ✅ YES (all evaluated locally)'
  puts '   - Ruby SDK now has cohort parity: ✅ YES'

when 4
  puts "\n#{'=' * 60}"
  puts 'FLAG DEPENDENCIES EXAMPLES'
  puts '=' * 60
  puts '🔗 Testing flag dependencies with local evaluation...'
  puts '   Flag structure: \'test-flag-dependency\' depends on \'beta-feature\' being enabled'
  puts ''
  puts "📋 Required setup (if 'test-flag-dependency' doesn't exist):"
  puts "   1. Create feature flag 'beta-feature':"
  puts "      - Condition: email contains '@example.com'"
  puts '      - Rollout: 100%'
  puts "   2. Create feature flag 'test-flag-dependency':"
  puts "      - Condition: flag 'beta-feature' is enabled"
  puts '      - Rollout: 100%'
  puts ''

  posthog.logger.level = Logger::DEBUG

  # Test @example.com user (should satisfy dependency if flags exist)
  result1 = posthog.is_feature_enabled(
    'test-flag-dependency',
    'example_user',
    person_properties: { 'email' => 'user@example.com' },
    only_evaluate_locally: true
  )
  puts "✅ @example.com user (test-flag-dependency): #{result1}"

  # Test non-example.com user (dependency should not be satisfied)
  result2 = posthog.is_feature_enabled(
    'test-flag-dependency',
    'regular_user',
    person_properties: { 'email' => 'user@other.com' },
    only_evaluate_locally: true
  )
  puts "❌ Regular user (test-flag-dependency): #{result2}"

  # Test beta-feature directly for comparison
  beta1 = posthog.is_feature_enabled(
    'beta-feature',
    'example_user',
    person_properties: { 'email' => 'user@example.com' },
    only_evaluate_locally: true
  )
  beta2 = posthog.is_feature_enabled(
    'beta-feature',
    'regular_user',
    person_properties: { 'email' => 'user@other.com' },
    only_evaluate_locally: true
  )
  puts "📊 Beta feature comparison - @example.com: #{beta1}, regular: #{beta2}"

  # Test pineapple -> blue -> breaking-bad chain
  dependent_result3 = posthog.get_feature_flag(
    'multivariate-root-flag',
    'regular_user',
    person_properties: { 'email' => 'pineapple@example.com' },
    only_evaluate_locally: true
  )
  if dependent_result3.to_s == 'breaking-bad'
    puts "✅ 'multivariate-root-flag' with email pineapple@example.com succeeded"
  else
    puts "     ❌ Something went wrong evaluating 'multivariate-root-flag' with pineapple@example.com. " \
         "Expected 'breaking-bad', got '#{dependent_result3}'"
  end

  # Test mango -> red -> the-wire chain
  dependent_result4 = posthog.get_feature_flag(
    'multivariate-root-flag',
    'regular_user',
    person_properties: { 'email' => 'mango@example.com' },
    only_evaluate_locally: true
  )
  if dependent_result4.to_s == 'the-wire'
    puts "✅ 'multivariate-root-flag' with email mango@example.com succeeded"
  else
    puts '     ❌ Something went wrong evaluating multivariate-root-flag with mango@example.com. ' \
         "Expected 'the-wire', got '#{dependent_result4}'"
  end

  puts "\n🎯 Results Summary:"
  puts "   - Flag dependencies evaluated locally: #{result1 == result2 ? '❌ NO' : '✅ YES'}"
  puts '   - Zero API calls needed: ✅ YES (all evaluated locally)'
  puts '   - Ruby SDK supports flag dependencies: ✅ YES'

when 5
  puts "\n#{'=' * 60}"
  puts 'FEATURE FLAG PAYLOAD EXAMPLES'
  puts '=' * 60

  posthog.logger.level = Logger::DEBUG

  puts '📦 Testing feature flag payloads...'
  puts "test-flag payload: #{posthog.get_feature_flag_payload('test-flag', 'distinct_id')}"
  puts "test-flag payload (match=true): #{posthog.get_feature_flag_payload('test-flag', 'distinct_id',
                                                                           match_value: true)}"
  puts "All flags and payloads: #{posthog.get_all_flags_and_payloads('distinct_id')}"
  puts "Remote config payload: #{posthog.get_remote_config_payload('secret-encrypted-flag')}"

when 6
  puts "\n🔄 Running all examples..."

  # Run example 1
  puts "\n#{'🔸' * 20} IDENTIFY AND CAPTURE #{'🔸' * 20}"
  posthog.logger.level = Logger::DEBUG
  puts '📊 Capturing events...'
  posthog.capture({ distinct_id: 'distinct_id', event: 'event',
                    properties: { 'property1' => 'value', 'property2' => 'value' }, send_feature_flags: true })
  puts '🔗 Creating alias...'
  posthog.alias(distinct_id: 'distinct_id', alias: 'new_distinct_id')
  puts '👤 Identifying user...'
  posthog.identify(distinct_id: 'new_distinct_id', properties: { 'email' => 'something@something.com' })

  # Run example 2
  puts "\n#{'🔸' * 20} FEATURE FLAGS #{'🔸' * 20}"
  puts '🏁 Testing basic feature flags...'
  puts "beta-feature: #{posthog.is_feature_enabled('beta-feature', 'distinct_id')}"
  puts "Sydney user: #{posthog.is_feature_enabled('test-flag', 'random_id_12345',
                                                  person_properties: { '$geoip_city_name' => 'Sydney' })}"

  # Run example 3
  puts "\n#{'🔸' * 20} COMPLEX COHORTS #{'🔸' * 20}"
  posthog.logger.level = Logger::INFO
  puts '🧩 Testing complex cohort evaluation...'
  result1 = posthog.is_feature_enabled('test-complex-cohort-flag', 'verified_user',
                                       person_properties: { 'email' => 'user@example.com',
                                                            'is_email_verified' => 'true' },
                                       only_evaluate_locally: true)
  result2 = posthog.is_feature_enabled('test-complex-cohort-flag', 'posthog_user',
                                       person_properties: { 'email' => 'dev@posthog.com' }, only_evaluate_locally: true)
  puts "✅ Verified user: #{result1}, PostHog user: #{result2}"

  # Run example 4
  puts "\n#{'🔸' * 20} FLAG DEPENDENCIES #{'🔸' * 20}"
  posthog.logger.level = Logger::DEBUG
  puts '🔗 Testing flag dependencies...'
  dep_result1 = posthog.is_feature_enabled('test-flag-dependency', 'example_user',
                                           person_properties: { 'email' => 'user@example.com' },
                                           only_evaluate_locally: true)
  dep_result2 = posthog.is_feature_enabled('test-flag-dependency', 'regular_user',
                                           person_properties: { 'email' => 'user@other.com' },
                                           only_evaluate_locally: true)
  puts "✅ Flag dependencies: @example.com: #{dep_result1}, regular: #{dep_result2}"

  # Test multivariate dependency chains
  mv_result1 = posthog.get_feature_flag('multivariate-root-flag', 'regular_user',
                                        person_properties: { 'email' => 'pineapple@example.com' },
                                        only_evaluate_locally: true)
  mv_result2 = posthog.get_feature_flag('multivariate-root-flag', 'regular_user',
                                        person_properties: { 'email' => 'mango@example.com' },
                                        only_evaluate_locally: true)
  puts "✅ Multivariate chains: pineapple->#{mv_result1}, mango->#{mv_result2}"

  # Run example 5
  puts "\n#{'🔸' * 20} PAYLOADS #{'🔸' * 20}"
  posthog.logger.level = Logger::DEBUG
  puts '📦 Testing payloads...'
  puts "Payload: #{posthog.get_feature_flag_payload('test-flag', 'distinct_id')}"

when 7
  puts '👋 Goodbye!'
  posthog.shutdown
  exit

else
  puts '❌ Invalid choice. Please run again and select 1-7.'
  posthog.shutdown
  exit
end

puts "\n#{'=' * 60}"
puts '✅ Example completed!'
puts '=' * 60

posthog.shutdown
