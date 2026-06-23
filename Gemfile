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
  gem 'oj', '~> 3.17.3'
  gem 'prettier'
  gem 'railties', '~> 7.1'
  gem 'rake', '~> 13.2.1'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.75.6'
  gem 'timecop'
  gem 'tzinfo', '~> 2.0'
  gem 'webmock'
end
