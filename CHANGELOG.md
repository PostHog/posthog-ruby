# 2.0.0

Breaking changes:

1. Minimum PostHog version requirement: 1.38
2. Regular feature flag evaluation (i.e. by requesting from your PostHog servers) doesn't require a personal API key.
3. `Client` initialisation doesn't take the `api_host` parameter anymore. Instead, it takes the `host` parameter, which needs to be fully qualified. For example: `https://api.posthog.com` is valid, while `api.posthog.com` is not valid.
4. The log level by default is set to WARN. You can change it to DEBUG if you want to debug the client by running `client.logger.level = Logger::DEBUG`, where client is your initialized `PostHog::Client` instance.
5. Default polling interval for feature flags is now set at 30 seconds. If you don't want local evaluation, don't set a personal API key in the library.
6. Feature flag defaults are no more. Now, if a flag fails to compute for whatever reason, it will return `nil`. Otherwise, it returns either true or false. In case of `get_feature_flag`, it may also return a string variant value.

New Changes:

1. You can now evaluate feature flags locally (i.e. without sending a request to your PostHog servers) by setting a personal API key, and passing in groups and person properties to `is_feature_enabled` and `get_feature_flag` calls.
2. Introduces a `get_all_flags` method that returns all feature flags. This is useful for when you want to seed your frontend with some initial flags, given a user ID.


# 1.3.0 - 2022-06-24

- Add support for running the client in "No-op" mode for testing (https://github.com/PostHog/posthog-ruby/pull/15)

# 1.2.4 - 2022-05-30

- Fix `create_alias` call (https://github.com/PostHog/posthog-ruby/pull/14)

# 1.2.3 - 2022-01-18

- Fix `present?` call (https://github.com/PostHog/posthog-ruby/pull/12)

# 1.2.2 - 2021-11-22

- Add ability to disable SSL verification by passing `skip_ssl_verification` (https://github.com/PostHog/posthog-ruby/pull/11)

# 1.2.1 - 2021-11-19

- Add concurrent-ruby gem dependency (fixes #8)

# 1.1.0 - 2020-12-15

- Change default domain from `t.posthog.com` to `app.posthog.com`
