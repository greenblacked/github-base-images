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
make check IMAGE=ci-rust185   # build, then smoke-test
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

## What does not belong in an image

Project dependencies, application source, credentials, and project-specific build tools. Each
`test.sh` asserts their absence, and those assertions are the point — if you find yourself relaxing
one to make a build pass, that is usually the bug rather than the test.

Pinned tool versions (Terraform, kubectl, AWS CLI, Docker client in `ci-tools`; Composer in
`ci-php84`) are `ARG`s so a bump is a small change that CI revalidates. Dependabot does **not**
track these — it only updates each Dockerfile's `ARG BASE_IMAGE` — so they still move when a human
moves them. What has changed is that you no longer have to *notice*: the weekly
[pin drift](../.github/workflows/pin-drift.yml) job compares every one of them against its vendor's
current release and maintains a single tracking issue, opened when something falls behind and
closed when everything is current.

Run it yourself any time:

```bash
./scripts/check-pins.sh                 # table of every pin vs upstream
./scripts/check-pins.sh --only trivy    # just one
```

Exit codes are `0` current, `3` drift found, `1` a vendor endpoint was unreachable — so drift is
distinguishable from a broken check.

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

Two downloads are **not** checksummed, deliberately: the Docker static tarball (no `.sha256` is
published — the URL 404s) and the AWS CLI installer (detached GPG signature only, which would mean
adding `gnupg` and a pinned AWS public key to the build). Recording a hash computed from one of our
own downloads would attest only to what we happened to fetch, so those stay unverified and
labelled rather than given a checksum that looks authoritative and is not. Adding GPG verification
for the AWS CLI is a reasonable follow-up.

## Commit and PR conventions

Explain *why* in the commit body, not just what. This repository's comments and history lean
heavily on recording the reasoning behind a constraint, because most of the surprising decisions
here (why browsers are not baked in, why library vulnerabilities do not gate, why builds are native
rather than QEMU) are non-obvious and get re-litigated otherwise.
