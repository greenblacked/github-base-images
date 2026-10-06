# Contributing

## The short version

CI is the source of truth. Open a pull request and the full pipeline runs — lint, build on both
architectures on native runners, smoke test, all five Trivy scans, and both gates — with every
registry write skipped. A green PR run is the pre-merge proof.

## Local loop

You do not need to authenticate to `ghcr.io` to build anything here. PR builds and local builds
both use the upstream base directly, via each Dockerfile's `ARG BASE_IMAGE` default.

```bash
make list                     # images, discovered by globbing */Dockerfile.ci
make check IMAGE=ci-rust   # build, then smoke-test
make check-all                # every image
```

`make check` reproduces the build-and-smoke-test part of a PR run. It does **not** run the Trivy
scans or the vulnerability and secret gates — those stay CI's job, and they can fail a change that
passed locally.

Requires GNU make and a working Docker daemon. `PLATFORM=linux/amd64` cross-builds under emulation;
`TAG=` overrides the local `:test` tag.

## Before opening a PR

The `lint` job runs these first, so running them locally saves a round trip:

```bash
make lint
```

That runs the CI lint job's exact battery -- CI runs the same script -- so
shellcheck, hadolint and actionlint on the versions pinned in `scripts/lint.sh`
(DL3008 and DL3006 are ignored inline in the Dockerfiles, deliberately; see
[PR validation and linting](docs/pipeline.md#pr-validation-and-linting)), the
`images.json` cross-check, the
[vulnerability exceptions](docs/security.md#vulnerability-exceptions) check, and a
best-effort zizmor workflow audit. Engines are downloaded
once into the git-ignored `.lint-cache/` as checksum-verified release binaries.

## Adding another image

This is the authoritative checklist. There is no workflow to edit: the image list lives in one
place, [.github/images.json](.github/images.json), an array of `{image, version, mirror, upstream}`
entries. [build-and-push.yml](.github/workflows/build-and-push.yml) reads it and calls the reusable
per-image pipeline in [build-image.yml](.github/workflows/build-image.yml) once per entry — there
are no per-image jobs to copy any more.

To add an image:

1. Create `<image-name>/Dockerfile.ci` and `<image-name>/test.sh` following the existing pattern,
   and `chmod +x` the test script (the workflow and `make test` both execute it directly).
2. Add one entry to [.github/images.json](.github/images.json).
3. Add a `docker` ecosystem entry for the directory in
   [.github/dependabot.yml](.github/dependabot.yml).

Everything else is automatic: the `paths:` filter is the glob `ci-*/**`, the mirror job and the
build matrix are driven by `images.json`, the lint job cross-checks that every entry has a
directory and every `ci-*` directory has an entry, and the [Makefile](Makefile) discovers images
by globbing `*/Dockerfile.ci`. The `version` field is per image, which is how the Noble-based
images carry `noble-v1` and the Trixie-based ones `trixie-v1` while the rest are `bookworm-v1`.
A new image starts on its upstream's current distribution
([ADR 0005](docs/adr/0005-new-images-current-distro-retire-at-eol.md)), and the bar for adding one
at all is a concrete consumer — see [Future candidates](docs/images.md#future-candidates).

Rules that are easy to miss:

- **`chmod +x` the test script.** Both CI and `make test` execute it directly — and the lint job
  fails if it is missing or not executable.
- **Match the directory name and the `image` field** in `images.json`; the lint job cross-checks
  both directions.
- **Bump kubectl in both places.** It is pinned in `ci-tools` *and* `ci-cloud` so a cluster deploy
  behaves the same whichever image runs it. The lint job asserts the version and both checksums are
  identical, so updating one and not the other fails the build rather than shipping a version skew.
- **Bump Composer in both places.** It is pinned in `ci-php84` *and* `ci-php85`, with the same lint
  assertion on the version and checksum, for the same reason.
- **Make the new packages public** after the first publish: the `ci-*` image, and its `mirror-*`
  base if that is new too. See
  [Visibility and authentication](docs/images.md#visibility-and-authentication).

## What does not belong in an image

Project dependencies, application source, credentials, and project-specific build tools. Each
`test.sh` asserts their absence, and those assertions are the point — if you find yourself relaxing
one to make a build pass, that is usually the bug rather than the test.

Pinned tool versions (Terraform, kubectl, AWS CLI, Docker client in `ci-tools`; Composer in
`ci-php84` and `ci-php85`) are `ARG`s so a bump is a small change that CI revalidates. Dependabot does **not**
track these — it only updates each Dockerfile's `ARG BASE_IMAGE` — so they still move when a human
moves them. What has changed is that you no longer have to *notice*: the daily
[pin drift](.github/workflows/pin-drift.yml) job compares every one of them against its vendor's
current release and maintains a single tracking issue, opened when something falls behind and
closed when everything is current ([details](docs/pipeline.md#pin-drift)).

Run it yourself any time:

```bash
./scripts/check-pins.sh                 # table of every pin vs upstream
./scripts/check-pins.sh --only trivy    # just one
```

Exit codes are `0` current, `3` drift found, `1` a vendor endpoint was unreachable — so drift is
distinguishable from a broken check.

**Bumps make themselves.** The daily [pin bump](.github/workflows/pin-bump.yml) job opens one PR
per drifted tool whose release is at least seven days old, with the version and its checksums
rewritten from the vendor's own published files, and dispatches CI on it. Every one merges itself
once all four required checks are green and is published straight away. One with no vendor
checksum or a major version is labelled `needs-review` for information; label a PR `hold` to stop
it merging. The same script works locally, and the commands below remain the way to check a
checksum by hand ([ADR 0007](docs/adr/0007-automatic-updates.md),
[ADR 0008](docs/adr/0008-self-updating.md)):

```bash
./scripts/bump-pins.sh --unit kubectl            # both copies, version and checksums
./scripts/bump-pins.sh --unit terraform --to <VERSION>
```

Paired pins move as one unit, which keeps the lint parity checks green: kubectl in `ci-tools`
and `ci-cloud`, Composer in `ci-php84` and `ci-php85`, gitleaks in `ci-security` and
`security.yml`, npm and Playwright in `ci-node22` and `ci-node24`. hadolint and actionlint are
pinned in `scripts/lint.sh` with their per-platform checksums as named variables, so they move the
same way.

Where the vendor publishes a per-file SHA-256, the download is checked against it, and the
checksum is an `ARG` alongside the version. Bumping one of those is a **three**-line change —
version plus both per-architecture sums — because the checksums differ per architecture:

```bash
# Terraform publishes a combined sums file:
curl -s https://releases.hashicorp.com/terraform/<VERSION>/terraform_<VERSION>_SHA256SUMS \
  | grep -E 'linux_(amd64|arm64)\.zip'

# kubectl publishes one per artifact:
for a in amd64 arm64; do curl -s "https://dl.k8s.io/release/v<VERSION>/bin/linux/$a/kubectl.sha256"; echo; done
```

Composer is the exception. Its GitHub release carries no `.sha256` asset, so the `ARG` here
records a hash computed from the release artifact itself — trust-on-first-use rather than vendor
attestation. It detects a later substitution, not an originally bad artifact.

**`getcomposer.org` does publish a per-release digest** at
`https://getcomposer.org/download/<VERSION>/composer.phar.sha256sum`, which is strictly better than
a computed hash. It is unreachable from some restricted build and development networks — the same
reason the binary itself is fetched from GitHub rather than from there — so it could not be used
when this pin was last set. `scripts/bump-pins.sh` now takes the Composer checksum from there and
nowhere else: where it is unreachable the bump fails rather than falling back to hashing the
download. So the next Composer bump, automated or by hand with the script, upgrades this pin from
trust-on-first-use to vendor-attested, and the caveat above can go with it. The build's
`sha256sum --check` confirms the getcomposer.org digest matches the GitHub release asset.

Three downloads are **not** checksummed, deliberately: the Docker static tarball (no `.sha256` is
published — the URL 404s), the AWS CLI installer (detached GPG signature only, which would mean
adding `gnupg` and a pinned AWS public key to the build), and the gcloud CLI in `ci-cloud` (the
release bucket carries no `.sha256` companions). These stay unverified and labelled rather than
given a checksum that looks vendor-attested and is not, and their automated bumps are always
labelled `needs-review`. They still merge themselves when green: the full build, smoke tests and
vulnerability gate are the check on the version, and `hold` stops one.

That is admittedly inconsistent with Composer, which does carry a computed hash until its next
bump — the difference is historical rather than principled, and worth resolving in one direction
or the other. The
argument for extending trust-on-first-use to all four is that it detects a later substitution,
which is better than nothing; the argument against is that a computed hash in the same `ARG` shape
as a vendor-published one invites the reader to assume a guarantee that is not there. Adding GPG
verification for the AWS CLI would remove it from this list properly, and is the better fix.

## Commit and PR conventions

Explain *why* in the commit body, not just what. This repository's comments and history lean
heavily on recording the reasoning behind a constraint, because most of the surprising decisions
here (why browsers are not baked in, why only fixable vulnerabilities gate, why builds are native
rather than QEMU) are non-obvious and get re-litigated otherwise.
