# frozen_string_literal: true

require 'posthog'
require 'isolated/json_example'

describe 'with oj' do
  before do
    require 'oj'
    Oj.mimic_JSON
  end

  include_examples 'message_batch_json'
end
