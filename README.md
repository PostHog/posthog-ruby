# PostHog Ruby

Please see the main [PostHog docs](https://posthog.com/docs).

Specifically, the [Ruby integration](https://posthog.com/docs/integrations/ruby-integration) details.

## Questions?

### [Join our Slack community.](https://join.slack.com/t/posthogusers/shared_invite/enQtOTY0MzU5NjAwMDY3LTc2MWQ0OTZlNjhkODk3ZDI3NDVjMDE1YjgxY2I4ZjI4MzJhZmVmNjJkN2NmMGJmMzc2N2U3Yjc3ZjI5NGFlZDQ)

## How to release

1. Get access to RubyGems from @yakkomajuri or @mariusandra
2. Update `lib/posthog/version.rb` with the new version. Commit the changes:

```shell
git commit -am "Version 1.2.2" .
git push && git push --tags 
```
3. Run

```shell
gem build *.gemspec
gem push *.gem
```

3. Authenticate with your RubyGems account and approve the publish!
