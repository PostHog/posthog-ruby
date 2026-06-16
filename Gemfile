# frozen_string_literal: true

required_bundler = Gem::Version.new('4.0.13')
if Gem::Version.new(Bundler::VERSION) < required_bundler
  abort "Bundler #{required_bundler}+ is required because this Gemfile enforces a 7-day RubyGems cooldown."
end

source 'https://rubygems.org', cooldown: 7
gemspec

gem 'concurrent-ruby', require: 'concurrent'
gem 'irb'

group :development, :test do
  gem 'activesupport', '~> 7.1'
  gem 'commander', '~> 5.0'
  gem 'oj', '~> 3.16.10'
  # Soft dependencies of posthog-rails' PostHog Logs feature, used by the logs
  # specs to exercise the real BatchLogRecordProcessor and OTLP exporter. Gated
  # on Ruby 3.3+ because opentelemetry-logs-sdk >= 0.5.0 drops 3.2 (which matches
  # the feature's documented requirement); on 3.2 the logs specs skip. The
  # >= 0.6.0 floor is required because the OTLP exporter encodes
  # LogRecordData#event_name, which only exists from 0.6.0 on (older pairings
  # raise NoMethodError on export).
  if RUBY_VERSION >= '3.3'
    gem 'opentelemetry-exporter-otlp-logs', require: false
    gem 'opentelemetry-logs-sdk', '>= 0.6.0', require: false
  end
  gem 'prettier'
  gem 'railties', '~> 7.1'
  gem 'rake', '~> 13.2.1'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.75.6'
  gem 'timecop'
  gem 'tzinfo', '~> 2.0'
  gem 'webmock'
end
