# frozen_string_literal: true

require 'spec_helper'
require 'action_controller'
require 'action_dispatch'

$LOAD_PATH.unshift File.expand_path('../../../posthog-rails/lib', __dir__)

require 'posthog/rails/configuration'

RSpec.describe PostHog::Rails::Configuration do
  subject(:config) { described_class.new }

  describe '#should_capture_exception?' do
    # MimeNegotiation::InvalidType is raised when a client sends a malformed
    # Accept / Content-Type header (typically scanner traffic). Rails maps it
    # to a 406 — see ActionDispatch::ExceptionWrapper.rescue_responses — so it
    # is not a bug worth capturing.
    {
      'ActionController::RoutingError' => ActionController::RoutingError.new('No route matches'),
      'ActionDispatch::Http::MimeNegotiation::InvalidType' =>
        ActionDispatch::Http::MimeNegotiation::InvalidType.new('"foo" is not a valid MIME type')
    }.each do |name, exception|
      it "excludes #{name} by default" do
        expect(config.should_capture_exception?(exception)).to be false
      end
    end

    it 'captures application exceptions that are not in the excluded list' do
      exception = StandardError.new('something broke')
      expect(config.should_capture_exception?(exception)).to be true
    end

    it 'honours user-supplied excluded_exceptions in addition to defaults' do
      config.excluded_exceptions = ['MyApp::IgnorableError']
      stub_const('MyApp::IgnorableError', Class.new(StandardError))
      expect(config.should_capture_exception?(MyApp::IgnorableError.new)).to be false
      # defaults still apply
      expect(config.should_capture_exception?(ActionController::RoutingError.new('x'))).to be false
    end
  end

  describe 'PostHog Logs defaults' do
    it 'defaults logs to disabled with forwarding ready' do
      expect(config.logs_enabled).to be false
      expect(config.forward_rails_logger).to be true
      expect(config.logs_level).to be_nil
      expect(config.logs_max_records_per_minute).to eq(6_000)
      expect(config.logs_resource_attributes).to eq({})
    end
  end
end
