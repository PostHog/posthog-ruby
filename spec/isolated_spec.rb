# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe 'JSON compatibility in isolated processes' do
  %w[with_active_support with_oj with_active_support_and_oj].each do |configuration|
    it "serializes batches #{configuration}" do
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, '-Ilib', '-Ispec', Gem.bin_path('rspec-core', 'rspec'),
        "spec/isolated/#{configuration}.rb"
      )

      expect(status).to be_success, "#{stdout}\n#{stderr}"
      expect(stdout).to include('1 example, 0 failures')
    end
  end
end
