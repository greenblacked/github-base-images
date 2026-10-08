# Review instructions

This repository builds and publishes public container images that other repositories build on, so
a change here reaches every consumer. Review for correctness and supply-chain safety first; skip
style nits that `make lint` already enforces.

## Security checks on every pull request

Flag as blocking:

- Credentials, tokens or keys committed anywhere, including docs, scripts and test fixtures.
- A workflow `uses:` that is not pinned to a full commit SHA with the version in a trailing comment.
- Workflow permissions broader than the job needs, a `pull_request_target` trigger, or `${{ }}`
  from untrusted input (PR titles, branch names, comments) interpolated into a `run:` block.
- A registry login or write reachable from a pull request or a fork build.
- A downloaded binary without a pinned version and a checksum or signature check, or a checksum
  changed without the version it belongs to.
- `curl | sh` installs, `latest` tags, or a base image referenced by tag where the pipeline pins
  or mirrors it.
- Anything that weakens a gate: skipped tests, `continue-on-error` on a gating step, a loosened
  vulnerability threshold, or an expired or open-ended entry in `.github/vuln-exceptions.json`.
- Project-specific dependencies, source or credentials baked into an image.

## Image and pipeline checks

- A new or removed image needs matching changes in `.github/images.json`, `.github/dependabot.yml`,
  the README catalog and `docs/images.md`; `scripts/image-lifecycle.sh check` enforces this.
- Every image has an executable `test.sh`, and every tool added to a Dockerfile is asserted in it.
- A change to an image's contents needs the version tag bumped; a rebuild-only change must not.
- Pin bumps must move a version together with its checksums, as `scripts/bump-pins.sh` does.

## Required checks

A pull request is merged on `CI result`, `Repository secret scan`, `CodeQL (workflows)` and
`Dependency review`. Ask for a fix, not a bypass, when one fails. Run `make lint` before pushing.

## Review conduct

- Say what is wrong, why it matters and the smallest fix. Mark anything that is not a bug as a
  suggestion.
- Do not approve changes that touch `.github/workflows/` or `scripts/` without checking them
  against the security list above.

## Attribution

Do not add AI-tool attribution or generated-by footers to commits, comments, reviews or pull
request text. If an integration appends one, remove it from the published content when possible.
