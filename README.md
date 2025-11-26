# PostHog Ruby

Please see the main [PostHog docs](https://posthog.com/docs).

Specifically, the [Ruby integration](https://posthog.com/docs/integrations/ruby-integration) details.

> [!IMPORTANT]
> Supports Ruby 3.2 and above
>
> We will lag behind but generally not support versions which are end-of-life as listed here https://www.ruby-lang.org/en/downloads/branches/
>
> All 2.x versions of the PostHog Ruby library are compatible with Ruby 2.0 and above if you need Ruby 2.0 support.

## Developing Locally

1. Install `asdf` to manage your Ruby version: `brew install asdf`
1. Install Ruby's plugin via `asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git`
1. Make `asdf` install the required version by running `asdf install`
1. Run `bundle install` to install dependencies

## Running example file

1. Build the `posthog-ruby` gem by calling: `gem build posthog-ruby.gemspec`.
2. Install the gem locally: `gem install ./posthog-ruby-<version>.gem`
3. Run `ruby example.rb`

## Testing

1. Run `bin/test` (this ends up calling `bundle exec rspec`)
2. An example of running specific tests: `bin/test spec/posthog/client_spec.rb:26`

## How to release

1. Get access to RubyGems from @dmarticus, @daibhin or @mariusandra
2. Install [`gh`](https://cli.github.com/) and authenticate with `gh auth login`
3. Update `lib/posthog/version.rb` with the new version & add to `CHANGELOG.md` making sure to add the current date. Commit the changes:

```shell
VERSION=1.2.3 # Replace with the new version here
git commit -am "Version $VERSION"
git tag -a $VERSION -m "Version $VERSION"
git push && git push --tags
gh release create $VERSION --generate-notes --fail-on-no-commits
```

4. Run

```shell
gem build posthog-ruby.gemspec
gem push "posthog-ruby-$VERSION.gem"
```

5. Authenticate with your RubyGems account and approve the publish!
