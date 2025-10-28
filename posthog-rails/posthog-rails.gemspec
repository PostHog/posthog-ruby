# frozen_string_literal: true

require File.expand_path('../lib/posthog/version', __dir__)

Gem::Specification.new do |spec|
  spec.name = 'posthog-rails'
  spec.version = PostHog::VERSION
  spec.files = Dir.glob('lib/**/*')
  spec.require_paths = ['lib']
  spec.summary = 'PostHog integration for Rails'
  spec.description = 'Automatic exception tracking and instrumentation for Ruby on Rails applications using PostHog'
  spec.authors = ['PostHog']
  spec.email = 'hey@posthog.com'
  spec.homepage = 'https://github.com/PostHog/posthog-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Rails dependency - support Rails 5.2+
  spec.add_dependency 'railties', '>= 5.2.0'
  # Core PostHog SDK
  spec.add_dependency 'posthog-ruby', "~> #{PostHog::VERSION.split('.')[0..1].join('.')}"
end
