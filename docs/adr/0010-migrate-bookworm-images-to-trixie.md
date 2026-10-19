# 0010 — Migrate the Bookworm images to Trixie under a new tag; freeze the old one

**Status:** accepted (2026-10-19); supersedes the "existing images are not migrated" part of
[0005](0005-new-images-current-distro-retire-at-eol.md)

## Decision

Every image built on Debian 12 Bookworm moves to Debian 13 Trixie, on the matching upstream tag,
and changes its version line from `bookworm-v1` to `trixie-v1`:

- `ci-tools`, `ci-cloud`, `ci-security`, `ci-db`: `debian:bookworm-slim` to `debian:trixie-slim`;
- `ci-node22`, `ci-node24`: `node:2X-bookworm-slim` to `node:2X-trixie-slim`;
- `ci-python312`, `ci-python313`: `python:3.1X-slim-bookworm` to `python:3.1X-slim-trixie`;
- `ci-ruby34`: `ruby:3.4-slim-bookworm` to `ruby:3.4-slim-trixie`;
- `ci-php84`: `php:8.4-cli-bookworm` to `php:8.4-cli-trixie`;
- `ci-go`, `ci-rust`: `golang:1-bookworm` and `rust:1-bookworm` to `golang:1-trixie` and
  `rust:1-trixie`, still the full variants, not slim.

`ci-dotnet8` and `ci-dotnet9` stay on Bookworm: they retire after 2026-11-10 (0005), weeks away.

The old `bookworm-v1` tag of each moved image is **frozen**: it keeps pointing at its last digest
and stays pullable, but nothing rebuilds, re-scans or re-tags it again.

## Why

- **The remaining OS-package CVEs could not be fixed any other way.** The daily rebuild runs
  `apt-get upgrade`, which brings in every fix Debian publishes. Bookworm's regular security
  support has ended and it is on reduced Debian LTS coverage, so a growing share of its findings
  never get a fix to pick up. Trixie is the supported stable release.
- **A new tag, not the old one moved underneath consumers.** A distribution change is a change to
  an image's contents: package names differ (the 64-bit `time_t` transition renamed `libasound2`,
  `libatk1.0-0` and others), and so do the versions of everything from glibc to OpenSSL. A job
  that `apt-get install`s extra packages can break. Moving `bookworm-v1` to Trixie in place would
  make that happen on a daily rebuild, unannounced; a new tag makes it a change each consumer
  makes deliberately.
- **Frozen rather than kept building.** Rebuilding both lines would double the build, the scans
  and the exceptions to maintain for every moved image, to keep a line alive whose distribution
  is the reason for the move. A frozen tag still works for anyone who has not switched yet, and
  the README, `docs/images.md` and SECURITY.md say it is no longer patched.

## Consequences

- `images.json` carries `trixie-v1` for the moved images, so publishing tags only `trixie-v1`;
  `bookworm-v1` is never pushed for them again.
- The Docker CLI in `ci-tools` is installed from Docker's `trixie` suite
  (`5:<version>-<revision>~debian.13~trixie`), and `scripts/bump-pins.sh` and
  `scripts/check-pins.sh` read `dists/trixie`.
- Microsoft publishes no `trixie` suite of `packages.microsoft.com/repos/azure-cli` and builds its
  Debian package for Bookworm only, and its Debian 13 repository does not carry azure-cli. So
  `ci-cloud` installs the `bookworm` build, from the same signed repository, on Trixie. That
  package bundles its own Python, and its system dependencies (libssl3, provided on Trixie by
  `libssl3t64`, libffi8, libbz2-1.0, libuuid1, zlib1g, libgcc-s1) all resolve. The suite is the
  `AZURE_CLI_SUITE` argument in `ci-cloud/Dockerfile.ci`.
- Findings in vendor Go binaries (kubectl, terraform, gcloud's helpers, gitleaks, cosign, grype,
  syft, trivy, golang-migrate) do not depend on the distribution. Their exceptions in
  `.github/vuln-exceptions.json` stay, and they wait for vendor releases; nothing is built from
  source here.

## Revisit if

Microsoft publishes a `trixie` suite for azure-cli (switch `AZURE_CLI_SUITE`), or Debian 14
Forky becomes stable, which raises the same question for every `trixie-v1` image.
