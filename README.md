# posthog-ruby

Add this to your gemfile:

```ruby
gem "posthog-ruby"
```

Then run the following code to send events

```ruby
posthog = PostHog::Client.new({
  api_key: "my_key",
  on_error: Proc.new { |status, msg| print msg }
})

posthog.capture({
  distinct_id: "user:123",
  event: "sent message",
  properties: {
    message_id: 3212
  }
})

posthog.identify({
  distinct_id: "user:123",
  properties: {
    email: 'john@doe.com',
    pro_user: false
  }
})

posthog.alias({
  distinct_id: "user:123",
  alias: "user:12345",
})
```
