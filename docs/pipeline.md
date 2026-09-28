# Build pipeline

How an image gets from a `Dockerfile.ci` to `ghcr.io`: where the base comes from, what a pull
request runs, which images a run builds, how the multi-arch index is assembled, what the tags
mean, and how pinned versions are kept current. The security checks along the way are in
[security.md](security.md); the reasoning is recorded in the [ADRs](adr/README.md).

- [Overview](#overview)
- [Mirrored upstream base](#mirrored-upstream-base)
- [PR validation and linting](#pr-validation-and-linting)
- [Which images a run builds](#which-images-a-run-builds)
- [Architectures](#architectures)
- [Tags and rebuilds](#tags-and-rebuilds)
- [Digests and `digests.json`](#digests-and-digestsjson)
- [Pin drift](#pin-drift)

## Overview

The image list lives in one place: [.github/images.json](../.github/images.json), an array of
`{image, version, mirror, upstream}` entries.
[build-and-push.yml](../.github/workflows/build-and-push.yml) reads it and calls the reusable
per-image pipeline in [build-image.yml](../.github/workflows/build-image.yml) once per entry
([ADR 0002](adr/0002-images-json-reusable-workflow.md)). For each image a run builds: mirror the
base (on `main`), build and smoke-test each architecture on a native runner, scan and gate, push
the per-arch digests, merge them into one multi-arch index, sign and attest it, and verify the
result. Adding an image is covered in
[CONTRIBUTING.md](../CONTRIBUTING.md#adding-another-image).

## Mirrored upstream base

The workflow copies the upstream base into `ghcr.io` before building
([ADR 0001](adr/0001-mirror-upstream-bases.md)):

| Mirror | Upstream |
|---|---|
| `ghcr.io/greenblacked/mirror-node:22-bookworm-slim` | `node:22-bookworm-slim` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-node:24-bookworm-slim` | `node:24-bookworm-slim` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-python:3.14-slim-trixie` | `python:3.14-slim-trixie` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-python:3.13-slim-bookworm` | `python:3.13-slim-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-python:3.12-slim-bookworm` | `python:3.12-slim-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-golang:1-bookworm` | `golang:1-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-rust:1-bookworm` | `rust:1-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-ruby:4.0-slim-trixie` | `ruby:4.0-slim-trixie` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-ruby:3.4-slim-bookworm` | `ruby:3.4-slim-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-debian:bookworm-slim` | `debian:bookworm-slim` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-temurin:25-jdk-noble` | `eclipse-temurin:25-jdk-noble` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-temurin:21-jdk-noble` | `eclipse-temurin:21-jdk-noble` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-temurin:17-jdk-noble` | `eclipse-temurin:17-jdk-noble` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-php:8.5-cli-trixie` | `php:8.5-cli-trixie` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-php:8.4-cli-bookworm` | `php:8.4-cli-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-dotnet:10.0-noble` | `mcr.microsoft.com/dotnet/sdk:10.0-noble` (MCR) |
| `ghcr.io/greenblacked/mirror-dotnet:9.0-bookworm-slim` | `mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim` (MCR) |
| `ghcr.io/greenblacked/mirror-dotnet:8.0-bookworm-slim` | `mcr.microsoft.com/dotnet/sdk:8.0-bookworm-slim` (MCR) |

Builds then use the mirror, so they do not depend on Docker Hub availability or rate limits. The
Dockerfile takes a `BASE_IMAGE` build arg that defaults to upstream, so local builds still work
without authenticating to `ghcr.io`; CI overrides it with the mirror.

**The copy is by digest, not by tag.** The `mirror` job resolves each upstream tag to a digest
first, mirrors that exact digest (not the tag a second time), and then verifies the mirror
resolves back to it — failing the run rather than publishing on an unverified copy. This closes
the one integrity gap the rest of the pipeline doesn't have: every action is SHA-pinned and every
downloaded binary — including each lint engine — is checksum-verified, but until this check
existed the base image itself was copied purely by trusting whatever a mutable tag happened to
resolve to at copy time, with no record of which bytes were actually mirrored. Every publish run
records one `{upstream, tag, digest}` object per distinct base — into the run summary and into a
machine-readable **`bases` artifact** (`bases.json`), the mirror-boundary counterpart to
[`digests.json`](#digests-and-digestsjson) — so "were we affected by an upstream compromise during
window X" is answerable later without a rebuild.

This is deliberately scoped to the mirror boundary only. The Dockerfiles' `ARG BASE_IMAGE`
defaults (`python:3.13`, `node:22`, `golang:1`, …) stay tag-based on purpose — that's what lets
Dependabot propose base bumps and the weekly rebuild pick up upstream patches — freezing those to
a digest would break the update mechanism this repo depends on.

Make each `mirror-*` package public along with its `ci-*` image (the one-time step is in
[Visibility and authentication](images.md#visibility-and-authentication)). They are byte-identical
copies of images already public on Docker Hub, so privacy buys nothing — and making them public
removes any question of whether the build jobs can pull them. If one is left private and a build
fails to pull the mirror, grant this repository Read on the package via *Manage Actions access*.

Pull requests never touch the mirrors: PR builds use the upstream base directly, so a PR run
cannot mutate registry state — and the first PR adding a new image does not need its mirror to
exist yet.

## PR validation and linting

A PR runs the full per-image pipeline — build both architectures natively, smoke test, all five
Trivy scans, both gates, the OSV report — for **every image the `plan` job selects** (the changed
ones, or all of them when the pipeline itself changed; see
[Which images a run builds](#which-images-a-run-builds)), with every registry write skipped.
Publishing (mirror push, digest push, manifest tagging) happens only on `main`. A manually
dispatched run from another branch builds everything, upstream-only, with no registry writes.

A `lint` job runs first and cheaply, so a typo never spends runner minutes on multi-arch builds:
**hadolint** on every `*/Dockerfile.ci` (DL3008 is ignored inline — apt pins would go stale and
break the weekly rebuild, which is the actual update mechanism; DL3006 is ignored inline on the
`FROM ${BASE_IMAGE}` lines — the ARG default is tagged, hadolint just can't resolve it),
**actionlint** on the workflows, and **shellcheck** on every `*/test.sh` (SC2016 is ignored per
file — check strings are deliberately single-quoted so they expand inside the container, not on
the host). `make lint` runs the same battery locally; see
[Building and testing an image locally](images.md#building-and-testing-an-image-locally).

**Dependabot** ([.github/dependabot.yml](../.github/dependabot.yml)) keeps the workflow's action
pins and each image's base-image ref current with weekly PRs. Because PR validation runs the full
build/test/scan stack, a Dependabot bump arrives pre-verified — green means the updated base
already built, passed the smoke tests, and cleared both gates on both architectures.

Which checks the `main` ruleset requires, and why `CI result` stands in for every per-image job,
is in [Required checks](security.md#required-checks).

## Which images a run builds

A push or pull request builds **only the images whose directories changed** (a pull request that
changes none, and no pipeline file, builds nothing) — a one-line fix to `ci-ruby34` does not
rebuild the other twenty images or move `latest` on them. Changing the pipeline itself (either
workflow file, `images.json`, or the two scripts `build-image.yml` runs) rebuilds everything; a
change to `.github/vuln-exceptions.json` rebuilds the images whose entries changed. The weekly
schedule and `workflow_dispatch` always rebuild everything — the rebuild is the security-update
mechanism and is never narrowed. Every ambiguous case (force-push, missing diff base) falls back
to the full list: over-building costs minutes, under-building leaves a stale published image
nobody notices. The chosen set is printed in the `plan` job's summary.

Pushes to `main` are path-filtered: the `paths:` filter is the glob `ci-*/**` (plus the pipeline
files). Pull requests are not path-filtered, so that the required `CI result` check always
reports.

## Architectures

The tag is a multi-arch manifest list, so `docker pull` and `container:` resolve the right
architecture automatically — including natively on an Apple Silicon machine, with no
`--platform linux/amd64` and no emulation.

Each architecture is built, smoke-tested, and scanned on a **native runner** (`ubuntu-latest` for
amd64, `ubuntu-24.04-arm` for arm64), then a `merge` job assembles the manifest list from the
per-arch digests. Nothing is tagged until every architecture has passed its own gate.

This is deliberately not a QEMU build. Emulating the larger images' apt layers would be
extremely slow — `ci-node22`'s Playwright dependency expansion alone pulls in around 99 packages
on top of the 11-package shared baseline — and multi-platform builds cannot `load:` into the
Docker daemon, so the arm64 image could not be smoke-tested or scanned before publishing. arm64
runners are free for public repositories, which makes the native path both faster and better
tested.

Each published index is also asserted to contain **both** platforms before the merge job goes
green — a one-architecture manifest is exactly the failure nobody notices until an Apple Silicon
machine pulls it.

Pinning a digest still works normally: pin the manifest-list digest from the run summary, and it
stays correct on both architectures.

## Tags and rebuilds

- **`bookworm-v1`** is a rolling contract line, and so are **`trixie-v1`** and **`noble-v1`** —
  each image carries exactly one, per the [image catalog](../README.md#image-catalog). The weekly
  rebuild moves it to a fresh digest carrying distribution security updates, plus whatever the
  upstream runtime base picked up. It is bumped to `v2` only when the *contents* of the image
  change — a tool added or removed. Determinism in production comes from pinning a digest, not
  from the tag.
  - For `ci-rust` and `ci-go` the line is rolling in one extra respect: the **language toolchain
    minor moves too**, because those images track `rust:1-bookworm` and `golang:1-bookworm`
    ([why](images.md#go-and-rust)). That is a deliberate exception to "contents change ⇒ bump to
    v2" — under the strict reading every upstream Rust release would need a new tag, which would
    make the contract line meaningless for exactly the two images whose upstreams have no support
    lines. The guarantee those two carry is *current stable of a 1.x-compatible language*, not a
    fixed minor. If you need a fixed minor, pin a digest, or pin the toolchain per project with a
    `rust-toolchain.toml` or a `toolchain` directive in `go.mod`.
- **`latest`** exists for testing. Never use it in a protected deployment job.
- **Renamed or removed images keep their old package.** GHCR does not delete a package when this
  repository stops building it, and nothing in the pipeline can: the package simply drops out of
  the weekly rebuild and the Trivy re-scan while staying published and pullable. It then quietly
  accumulates unpatched CVEs, and a consumer still pointing at it sees a working pull and no
  signal at all. **Deleting the old package is therefore part of a rename, not an optional
  tidy-up.** `ci-rust185` and `ci-go125` were retired this way and should be deleted from the
  package settings. The same applies to images retired at end of support, such as
  [`ci-dotnet8` and `ci-dotnet9`](images.md#deprecated-ci-dotnet8-and-ci-dotnet9).
- **`<commit-sha>`** identifies the exact build.

Every image rebuilds on every push to `main` touching any image directory, weekly on a schedule,
and on demand via *Run workflow*.

**Why the rebuild actually refreshes anything.** "The rebuild carries Debian security updates"
holds only if `apt-get update && apt-get upgrade` genuinely re-runs, and a build cache will happily
reuse that layer forever. It did: for a period every rebuild re-tagged images whose packages were
installed whenever the cache was first written, and the repository's central claim was quietly
false until the vulnerability gate caught fixable postgresql CVEs in `ci-db` that an upgrade would
have fixed had it run at all. The gate was right; the cache was hiding the fix.

The GHA layer cache is therefore scoped per **UTC day**, so the apt layer cannot outlive a day.
Weekly scoping was the first attempt and proved too coarse: Trivy's database refreshes daily, so
between one rebuild and the next the gate could learn about a fix the cached layer was unable to
fetch — which is exactly what happened when Debian published `linux-libc-dev` 6.1.187-1 mid-week
and every pull request failed on 63 findings nobody could act on. Matching the cache epoch to the
database cadence closes that window. The cost is one cold build per image on each day anything
builds, which on a normal day is the scheduled rebuild — and that one wants to be cold.

> **Watch out:** GitHub disables scheduled workflows after 60 days with no repository activity. A
> repo like this one can easily sit untouched that long, and the weekly rebuild then stops
> silently while the image goes stale. If the last run is old, trigger the workflow manually to
> re-enable the schedule.

## Digests and `digests.json`

Each build prints the digest to pin, in its run summary under the Actions tab — and every publish
run also uploads a machine-readable **`digests` artifact** (`digests.json`, an array of
`{image, version, digest}`), so pinning can be automated instead of copied by hand:

```bash
run=$(gh api 'repos/greenblacked/github-base-images/actions/workflows/build-and-push.yml/runs?branch=main&status=success&per_page=1' \
  --jq '.workflow_runs[0].id')
gh run download "$run" -R greenblacked/github-base-images -n digests
jq -r '.[] | select(.image == "ci-node22") | .digest' digests.json
```

A change-detection run's `digests.json` covers only the images that run rebuilt; a weekly or
manually dispatched run always covers all of them. A run in which some image failed still
aggregates the ones that published and verified — its summary says how many of the planned images
that is — but the run is red, so the `status=success` query above will not pick it.

The digest is the manifest-list digest, so one pin covers both architectures. Having pinned it,
verify it before running it: see [Verifying a signature](security.md#verifying-a-signature).

## Pin drift

Most of this repository's supply chain is watched by something: Dependabot tracks the action pins
and each Dockerfile's `ARG BASE_IMAGE`, and the weekly rebuild plus the Trivy gate cover the OS
packages and the libraries the images carry. Its config carries a seven-day `cooldown` on every
ecosystem — nothing is adopted the day it ships, since the window between publication and
discovery is exactly when a same-day bump would pull in a compromised release — and one `groups`
rule for `github/codeql-action`, whose `init`, `analyze` and `upload-sarif` subpaths are one action
on one SHA. Without the grouping Dependabot opens a PR per subpath, and since CodeQL rejects `init`
and `analyze` on different versions, two of the three fail by construction while the third passes
as a third of a change.

The tools installed as pinned release binaries — Terraform, kubectl, the AWS CLI, the Docker
client, gcloud, Composer, Playwright, the five scanners in `ci-security`, and the osv-scanner
binary the pipeline itself runs — were the gap: nothing read them, so they moved only when a human
remembered. An audit found six behind at once.

[pin-drift.yml](../.github/workflows/pin-drift.yml) closes that gap. Weekly, it compares every
pinned version against the version its vendor currently ships and maintains **one** tracking issue
— opened when something falls behind, updated while it stays behind, closed automatically once
every pin is current.

It reports rather than gates. Drift is not a broken build; it is a bump someone should make
deliberately, with a fresh checksum, through the normal PR path. Failing builds over it would just
teach people to ignore a permanently red repository.

Two cautions when acting on that issue. It is only as fresh as its last weekly run, so re-dispatch
the workflow before working from the table — more than once a bump has been prepared against a
version already superseded. And the lint engines are not in it: `HADOLINT_VERSION` and
`ACTIONLINT_VERSION` in `scripts/lint.sh` are plain shell variables, which neither Dependabot nor
`check-pins.sh` reads, so they move only when a human moves them. They used to be worse. CI ran
`hadolint-action`, which bundles its own hadolint binary, so its version was coupled to
`HADOLINT_VERSION` with nothing enforcing it, and twice a Dependabot PR moving only the action was
green while putting local and CI on different linters. The `lint` job now runs `scripts/lint.sh`
itself, so there is one pinned version of each engine, in one file; the comments above the pins
and above the `lint` job in `build-and-push.yml` record that history.

```bash
./scripts/check-pins.sh              # the same check, locally
```

How to bump a pin, including its checksums, is in
[CONTRIBUTING.md](../CONTRIBUTING.md#what-does-not-belong-in-an-image).
