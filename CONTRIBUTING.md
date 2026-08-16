# Contributing

## The short version

CI is the source of truth. Open a pull request and the full pipeline runs — lint, build on both
architectures on native runners, smoke test, three Trivy scans, and both gates — with every
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

That runs the CI lint job's exact battery -- shellcheck, hadolint pinned to the
same version `hadolint-action` bundles in CI (DL3008 and DL3006 are ignored
inline in the Dockerfiles, deliberately), actionlint, the `images.json`
cross-check, and a best-effort zizmor workflow audit. Engines are downloaded
once into the git-ignored `.lint-cache/` as checksum-verified release binaries.

## Adding an image

The README's [Adding another image](README.md#adding-another-image) section is the authoritative
checklist. In short: a `Dockerfile.ci` and an **executable** `test.sh`, one entry in
`.github/images.json`, and a `docker` ecosystem entry in `.github/dependabot.yml`. There is no
workflow to edit — the pipeline reads `images.json`.

Two rules that are easy to miss:

- **`chmod +x` the test script.** Both CI and `make test` execute it directly — and the lint job
  fails if it is missing or not executable.
- **Match the directory name and the `image` field** in `images.json`; the lint job cross-checks
  both directions.
- **Bump kubectl in both places.** It is pinned in `ci-tools` *and* `ci-cloud` so a cluster deploy
  behaves the same whichever image runs it. The lint job asserts the version and both checksums are
  identical, so updating one and not the other fails the build rather than shipping a version skew.

## What does not belong in an image

Project dependencies, application source, credentials, and project-specific build tools. Each
`test.sh` asserts their absence, and those assertions are the point — if you find yourself relaxing
one to make a build pass, that is usually the bug rather than the test.

Pinned tool versions (Terraform, kubectl, AWS CLI, Docker client in `ci-tools`; Composer in
`ci-php84`) are `ARG`s so a bump is a small change that CI revalidates. Note that Dependabot does
**not** track these — it only updates each Dockerfile's `ARG BASE_IMAGE` — so they move when a
human moves them.

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
when this pin was last set. If you are on a network that can reach it, **verify against it and say
so in the PR**; that upgrades this pin from trust-on-first-use to vendor-attested and the caveat
above can go.

Either way, when bumping Composer, first confirm the method still reproduces the *current* pin
before trusting a hash it produces for a new one.

Three downloads are **not** checksummed, deliberately: the Docker static tarball (no `.sha256` is
published — the URL 404s), the AWS CLI installer (detached GPG signature only, which would mean
adding `gnupg` and a pinned AWS public key to the build), and the gcloud CLI in `ci-cloud` (the
release bucket carries no `.sha256` companions). These stay unverified and labelled rather than
given a checksum that looks vendor-attested and is not.

That is admittedly inconsistent with Composer, which does carry a computed hash — the difference
is historical rather than principled, and worth resolving in one direction or the other. The
argument for extending trust-on-first-use to all four is that it detects a later substitution,
which is better than nothing; the argument against is that a computed hash in the same `ARG` shape
as a vendor-published one invites the reader to assume a guarantee that is not there. Adding GPG
verification for the AWS CLI would remove it from this list properly, and is the better fix.

## Commit and PR conventions

Explain *why* in the commit body, not just what. This repository's comments and history lean
heavily on recording the reasoning behind a constraint, because most of the surprising decisions
here (why browsers are not baked in, why library vulnerabilities do not gate, why builds are native
rather than QEMU) are non-obvious and get re-litigated otherwise.
