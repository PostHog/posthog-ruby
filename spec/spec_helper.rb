require 'posthog'
require 'active_support/all'
require 'webmock/rspec'

RSpec.configure do |config|
  config.before(:each) do
    PostHog::Logging.logger = Logger.new('/dev/null') # Suppress all logging
  end
end

# Setting timezone for ActiveSupport::TimeWithZone to UTC
Time.zone = 'UTC'

API_KEY = 'testsecret'

CAPTURE = {
  event: 'Ruby Library test event',
  properties: {
    type: 'Chocolate',
    is_a_lie: true,
    layers: 20,
    timestamp: Time.new
  }
}

IDENTIFY = { '$set': { likes_animals: true, instrument: 'Guitar', age: 25 } }

ALIAS = { alias: 1234, distinct_id: 'abcd' }

GROUP = {}

PAGE = {}

SCREEN = { name: 'main' }

DISTINCT_ID = 1234
GROUP_ID = 1234

# Hashes sent to the client, snake_case
module Queued
  CAPTURE = CAPTURE.merge distinct_id: DISTINCT_ID
  IDENTIFY = IDENTIFY.merge distinct_id: DISTINCT_ID
  GROUP = GROUP.merge group_id: GROUP_ID, distinct_id: DISTINCT_ID
  PAGE = PAGE.merge distinct_id: DISTINCT_ID
  SCREEN = SCREEN.merge distinct_id: DISTINCT_ID
end

# Hashes which are sent from the worker, camel_cased
module Requested
  CAPTURE = CAPTURE.merge({ distinctId: DISTINCT_ID, type: 'capture' })

  IDENTIFY = IDENTIFY.merge({ distinctId: DISTINCT_ID, type: 'identify' })

  GROUP =
    GROUP.merge({ groupId: GROUP_ID, distinctId: DISTINCT_ID, type: 'group' })

  PAGE = PAGE.merge distinctId: DISTINCT_ID
  SCREEN = SCREEN.merge distinctId: DISTINCT_ID
end

# A backoff policy that returns a fixed list of values
class FakeBackoffPolicy
  def initialize(interval_values)
    @interval_values = interval_values
  end

  def next_interval
    raise 'FakeBackoffPolicy has no values left' if @interval_values.empty?
    @interval_values.shift
  end
end

# usage:
# it "should return a result of 5" do
#   eventually(options: {timeout: 1}) { long_running_thing.result.should eq(5) }
# end

module AsyncHelper
  def eventually(options = {})
    timeout = options[:timeout] || 2
    interval = options[:interval] || 0.1
    time_limit = Time.now + timeout
    loop do
      begin
        yield
        return
      rescue RSpec::Expectations::ExpectationNotMetError => error
        raise error if Time.now >= time_limit
        sleep interval
      end
    end
  end
end

include AsyncHelper
