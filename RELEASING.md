# Releasing

Both `posthog-ruby` and `posthog-rails` are released together with the same version number.

1. Create a PR that:
   - Updates `lib/posthog/version.rb` with the new version
   - Updates `CHANGELOG.md` with the changes and current date

2. Add the `release` label to the PR

3. Merge the PR to `main`

4. The release workflow will:
   - Notify the Client Libraries team in Slack
   - Wait for approval via the GitHub `Release` environment
   - Publish both gems to RubyGems (via trusted publishing)
   - Create and push a git tag

5. Approve the release in GitHub when prompted

The workflow handles publishing both `posthog-ruby` and `posthog-rails` in the correct order (since `posthog-rails` depends on `posthog-ruby`).
