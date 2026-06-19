# Releasing

This repository uses [Changesets](https://github.com/changesets/changesets) for version management and changelog generation, with GitHub Actions publishing `posthog-ruby` and `posthog-rails` to RubyGems.

The gems are versioned and released independently. Add the changeset to the package that changed (`posthog-ruby` or `posthog-rails`); if both changed, select both packages. `posthog-rails` is not bumped automatically when `posthog-ruby` changes, so Rails releases must be selected intentionally.

## How to release

### 1. Add a changeset

When making changes that should be released, add a changeset:

```bash
pnpm changeset
```

This will prompt you to:
- select the changed package or packages (`posthog-ruby` and/or `posthog-rails`)
- select the release type (`patch`, `minor`, or `major`) for each package
- write a summary of the change

The changeset file will be created in the `.changeset/` directory.

### 2. Create a pull request

Create a PR with your code changes and the changeset file.

### 3. Merge the PR

No release label is required. When the PR is merged to `main`, the release workflow will automatically:

1. Check for pending changesets
2. Notify the Client Libraries team in Slack for approval
3. Wait for approval via the GitHub `Release` environment
4. Once approved:
   - Apply changesets and bump the changed package `package.json` files
   - Update the changed package changelog (`posthog-ruby/CHANGELOG.md` or `posthog-rails/CHANGELOG.md`)
   - Sync package versions to the Ruby version files
   - Commit the version bump to `main`
   - Publish only the packages whose versions changed
   - Create package-specific git tags and GitHub releases, for example `posthog-ruby-v3.13.1` or `posthog-rails-v3.14.0`

When both packages changed, the workflow publishes `posthog-ruby` first, then `posthog-rails`, since `posthog-rails` depends on `posthog-ruby`. The Rails gemspec pins its `posthog-ruby` dependency to the exact core SDK version present in the release commit, so Rails-only releases intentionally keep using the latest core SDK version recorded on `main`.

## Manual trigger

You can also manually trigger the release workflow from the Actions tab, as long as there are pending changesets.
