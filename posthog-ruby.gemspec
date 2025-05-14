require File.expand_path('lib/posthog/version', __dir__)

Gem::Specification.new do |spec|
  spec.name = 'posthog-ruby'
  spec.version = PostHog::VERSION
  spec.files = Dir.glob('{lib,bin}/**/*')
  spec.require_paths = ['lib']
  spec.bindir = 'bin'
  spec.executables = ['posthog']
  spec.summary = 'PostHog library'
  spec.description = 'The PostHog ruby library'
  spec.authors = ['']
  spec.email = 'hey@posthog.com'
  spec.homepage = 'https://github.com/PostHog/posthog-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 2.0'

  spec.add_dependency 'concurrent-ruby', '~> 1'

  # Used in the executable testing script
  spec.add_development_dependency 'commander', '~> 4.4'

  # Used in specs
  spec.add_development_dependency 'activesupport', '~> 7.1'
  spec.add_development_dependency 'oj', '~> 3.16.3' if RUBY_VERSION >= '2.0' && RUBY_PLATFORM != 'java'
  spec.add_development_dependency 'rake', '~> 13.1'
  spec.add_development_dependency 'rspec', '~> 3.13'
  spec.add_development_dependency 'rubocop', '~> 1.57.2' if RUBY_VERSION >= '2.1'
  spec.add_development_dependency 'tzinfo', '~> 2.0'
end
