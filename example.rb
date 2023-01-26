# PostHog Ruby library example

# Import the library
require 'posthog-ruby'

posthog = PostHog::Client.new({
   api_key: "", # You can find this key on the /setup page in PostHog
   personal_api_key: "", # Required for local feature flag evaluation
   host: "http://localhost:8000", # Where you host PostHog. You can remove this line if using app.posthog.com
   on_error: Proc.new { |status, msg| print msg },
   feature_flags_polling_interval: 10, # How often to poll for feature flags
})
posthog.logger.level = Logger::DEBUG
# Capture an event
posthog.capture({distinct_id: "distinct_id", event: "event", properties: {"property1": "value", "property2": "value"}, send_feature_flags: true})

puts(posthog.is_feature_enabled("beta-feature", "distinct_id"))
puts(posthog.is_feature_enabled("beta-feature", "new_distinct_id"))
puts(posthog.is_feature_enabled("beta-feature", "distinct_id", {"company" => "id:5"}))


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

# this will not change the property (because it was already set)
posthog.capture({distinct_id: "new_distinct_id", event: "signup", properties: { "$set_once": {"self_serve_signup": false}}})

posthog.capture({distinct_id: "new_distinct_id", event: "signup", properties: { "$set": {"current_browser": "Chrome"}}})
posthog.capture({distinct_id: "new_distinct_id", event: "signup", properties: { "$set": {"current_browser": "Firefox"}}})


#############################################################################################
# Feature flag local evaluation examples
# requires a personal API key to work
#############################################################################################

# Assume test-flag has `City Name = Sydney` as a person property set, then this will evaluate locally & return true
puts posthog.is_feature_enabled("test-flag", "random_id_12345", person_properties: {"$geoip_city_name" => "Sydney"})

puts posthog.is_feature_enabled("test-flag", "distinct_id_random_22", person_properties={"$geoip_city_name": "Sydney"}, only_evaluate_locally: true)


puts posthog.get_all_flags("distinct_id_random_22")
puts posthog.get_all_flags("distinct_id_random_22", only_evaluate_locally: true)
puts posthog.get_all_flags("distinct_id_random_22", person_properties: {"$geoip_city_name": "Sydney"}, only_evaluate_locally: true)


#############################################################################################
# Feature flag payload examples
# requires a personal API key to work
#############################################################################################

puts posthog.get_feature_flag_payload("test-flag", "distinct_id")
puts posthog.get_feature_flag_payload("test-flag", "distinct_id", match_value: true)
puts posthog.get_all_flags_and_payloads("distinct_id")

posthog.shutdown()
