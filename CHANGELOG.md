# Changelog

Notable changes to the published images: what a consumer has to act on. Routine rebuilds and
automated pin bumps are not listed; the commit history and each run's `digests.json` cover those.

## 2026-10-19: Bookworm images move to Debian 13 Trixie (`trixie-v1`)

Every image that was built on Debian 12 Bookworm, except `ci-dotnet8` and `ci-dotnet9`, now
builds on Debian 13 Trixie and publishes the `trixie-v1` tag:

- `ci-tools`, `ci-cloud`, `ci-security`, `ci-db`: `debian:trixie-slim`
- `ci-node22`, `ci-node24`: `node:22-trixie-slim`, `node:24-trixie-slim`
- `ci-python312`, `ci-python313`: `python:3.12-slim-trixie`, `python:3.13-slim-trixie`
- `ci-ruby34`: `ruby:3.4-slim-trixie`
- `ci-php84`: `php:8.4-cli-trixie`
- `ci-go`, `ci-rust`: `golang:1-trixie`, `rust:1-trixie` (full variants, as before)

**Action needed:** change `:bookworm-v1` to `:trixie-v1` for these images. Their `bookworm-v1`
tags are **frozen** at their last digest. They still pull, but they are no longer rebuilt,
re-scanned or patched. A digest pin needs a new digest from a `trixie-v1` build.

- Trixie renamed some libraries in its 64-bit `time_t` transition (`libasound2` is now
  `libasound2t64`, and so on). Jobs that `apt-get install` extra packages by their Bookworm
  names may need the new names.
- Tool versions are unchanged. The Docker CLI in `ci-tools` now comes from Docker's `trixie`
  suite. The Azure CLI in `ci-cloud` still comes from Microsoft's `bookworm` suite, because
  Microsoft publishes no `trixie` build yet.
- `ci-dotnet8` and `ci-dotnet9` stay on `bookworm-v1` until they retire after 2026-11-10.
  Move to `ci-dotnet10` (`noble-v1`).
- Each build's job summary now has a line per image and architecture with Trivy's finding counts
  by severity, split into fixable and unfixed.

Details: [docs/images.md](docs/images.md#the-trixie-migration) and
[ADR 0010](docs/adr/0010-migrate-bookworm-images-to-trixie.md).
