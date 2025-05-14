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
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.add_dependency 'concurrent-ruby', '~> 1'
end
