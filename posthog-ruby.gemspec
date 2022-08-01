require File.expand_path('../lib/posthog/version', __FILE__)

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
  
  spec.add_dependency "concurrent-ruby", "~> 1", "< 1.1.10"

  # TODO: timertask timeout pinning? "concurrent-ruby", "~> 1", "< 1.1.10"

  # Used in the executable testing script
  spec.add_development_dependency 'commander', '~> 4.4'

  # Used in specs
  spec.add_development_dependency 'rake', '~> 10.3'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'tzinfo', '1.2.1'
  spec.add_development_dependency 'activesupport', '~> 4.1.11'
  if RUBY_VERSION >= '2.0' && RUBY_PLATFORM != 'java'
    spec.add_development_dependency 'oj', '~> 3.6.2'
  end
  if RUBY_VERSION >= '2.1'
    spec.add_development_dependency 'rubocop', '~> 0.51.0'
  end
  spec.add_development_dependency 'codecov', '~> 0.1.4'
end
