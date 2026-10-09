# frozen_string_literal: true

required_bundler = Gem::Version.new('4.0.13')
if Gem::Version.new(Bundler::VERSION) < required_bundler
  abort "Bundler #{required_bundler}+ is required because this Gemfile enforces a 7-day RubyGems cooldown."
end

source 'https://rubygems.org', cooldown: 7
gemspec

gem 'concurrent-ruby', require: 'concurrent'
gem 'irb'

rails_version = ENV.fetch('RAILS_VERSION', '~> 7.1')

group :development, :test do
  gem 'activesupport', rails_version
  gem 'commander', '~> 5.0'
  gem 'mcp', '>= 1.4'
  gem 'oj', '~> 3.17.7'
  gem 'prettier'
  gem 'railties', rails_version
  gem 'rake', '~> 13.4.2'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.91.0'
  gem 'timecop'
  gem 'tzinfo', '~> 2.0'
  gem 'webmock'
end
