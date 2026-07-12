# Releasing Engram

Do not create a release tag until every PR intended for the release is merged. Release from
the resulting `main` commit.

1. Update `CHANGELOG.md` and `Engram::VERSION` together; confirm the release heading and gem
   version match.
2. Run every gate: syntax validation, the full unit suite, StandardRB, `rake eval`, and the
   Postgres/pgvector integration suite. Confirm CI's package/consumer smoke job passes.
3. Build and inspect the gem (`gem build engram.gemspec`, then `gem unpack engram-X.Y.Z.gem`).
   Confirm Ruby sources, generator templates, README, changelog, and license are present, with
   no development-only files or secrets.
4. Validate the candidate gem in an external Rails application, including installation,
   generator/migration, add/recall, and the configured pgvector and job adapters.
5. Before the first release, configure RubyGems Trusted Publishing for this GitHub repository,
   workflow `.github/workflows/release.yml`, and environment `release`. Protect that GitHub
   environment as appropriate. Do not add a long-lived RubyGems API-key secret.
6. After all changes are merged and checks are green, tag the matching commit as `vX.Y.Z` and
   push the tag. The release workflow rejects a tag that differs from `Engram::VERSION`.
7. After publishing, install from RubyGems into a clean isolated `GEM_HOME`, change outside the
   source tree, `require "engram"`, and run a minimal add/recall smoke. Verify the published
   version and package contents on RubyGems.org.
