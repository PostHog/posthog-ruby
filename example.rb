# PostHog Ruby library example

# Import the library
require 'posthog-ruby'

posthog = PostHog::Client.new({
   api_key: "phc_EKriuIZ8en7eBMCKkkgraMERQXkVM6g2gD050z2HIqf", # You can find this key on the /setup page in PostHog
   personal_api_key: "phx_XouNv5HTWQZkUvGkC4C8yq8cVmTI5eQ3oEkAWvniERn", # Required for local feature flag evaluation
   host: "http://localhost:8000", # Where you host PostHog. You can remove this line if using app.posthog.com
   on_error: Proc.new { |status, msg| print msg }
})

# Capture an event
posthog.capture({distinct_id: "distinct_id", event: "event", properties: {"property1": "value", "property2": "value"}, send_feature_flags: true})

puts(posthog.is_feature_enabled("beta-feature", "distinct_id"))
puts(posthog.is_feature_enabled("beta-feature", "new_distinct_id"))
puts(posthog.is_feature_enabled("beta-feature", "distinct_id", {"company": "id:5"}))

puts("sleeping")
# sleep 5

puts(posthog.is_feature_enabled("beta-feature", "distinct_id"))

# # Alias a previous distinct id with a new one

posthog.alias({distinct_id: "distinct_id", alias: "new_distinct_id"})

posthog.capture({distinct_id: "new_distinct_id", event: "event2", properties: {"property1": "value", "property2": "value"}})
posthog.capture({
   distinct_id: "new_distinct_id", event: "event-with-groups", properties: {"property1": "value", "property2": "value"}, groups: {"company": "id:5"}
})

# # Add properties to the person
posthog.identify({distinct_id: "new_distinct_id", properties: {"email": "something@something.com"}})

# Add properties to a group
posthog.group_identify({group_type: "company", group_key: "id:5", properties: {"employees": 11}})

# properties set only once to the person
posthog.capture({distinct_id: "new_distinct_id", event: "signup", properties: { "$set_once": {"self_serve_signup": true}}})

# sleep 3
# this will not change the property (because it was already set)
posthog.capture({distinct_id: "new_distinct_id", event: "signup", properties: { "$set_once": {"self_serve_signup": false}}})

posthog.capture({distinct_id: "new_distinct_id", event: "signup", properties: { "$set": {"current_browser": "Chrome"}}})
posthog.capture({distinct_id: "new_distinct_id", event: "signup", properties: { "$set": {"current_browser": "Firefox"}}})

posthog.shutdown()
