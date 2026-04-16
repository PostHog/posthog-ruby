# Releasing

This repository uses [Changesets](https://github.com/changesets/changesets) for version management and changelog generation, with GitHub Actions publishing both `posthog-ruby` and `posthog-rails` to RubyGems.

Both gems are released together with the same version number.

## How to release

### 1. Add a changeset

When making changes that should be released, add a changeset:

```bash
pnpm changeset
```

This will prompt you to:
- select the release type (`patch`, `minor`, or `major`)
- write a summary of the change

The changeset file will be created in the `.changeset/` directory.

### 2. Create a pull request

Create a PR with your code changes and the changeset file.

### 3. Add the `release` label

When the PR is ready to be released, add the `release` label.

### 4. Merge the PR

When a PR with the `release` label is merged to `main`, the release workflow will automatically:

1. Check for pending changesets
2. Notify the Client Libraries team in Slack for approval
3. Wait for approval via the GitHub `Release` environment
4. Once approved:
   - Apply changesets and bump `package.json`
   - Update `CHANGELOG.md`
   - Sync the version to `lib/posthog/version.rb`
   - Commit the version bump to `main`
   - Publish `posthog-ruby` and `posthog-rails` to RubyGems
   - Create a git tag and GitHub release

The workflow publishes `posthog-ruby` first, then `posthog-rails`, since `posthog-rails` depends on `posthog-ruby`.

## Manual trigger

You can also manually trigger the release workflow from the Actions tab, as long as there are pending changesets.
