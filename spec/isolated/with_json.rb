# frozen_string_literal: true

require 'posthog'
require 'isolated/json_example'

describe 'with json' do
  include_examples 'message_batch_json'
end
