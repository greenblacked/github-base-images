# base-images

[![Build and Push to GHCR](https://github.com/greenblacked/github-base-images/actions/workflows/build-and-push.yml/badge.svg?branch=main)](https://github.com/greenblacked/github-base-images/actions/workflows/build-and-push.yml)
[![Security](https://github.com/greenblacked/github-base-images/actions/workflows/security.yml/badge.svg?branch=main)](https://github.com/greenblacked/github-base-images/actions/workflows/security.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/greenblacked/github-base-images/badge)](https://scorecard.dev/viewer/?uri=github.com/greenblacked/github-base-images)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Central repository for building and publishing shared container images to `ghcr.io`.

The two workflow badges track **`main`**, not the latest run on any branch — so a red build badge
means the published images are stale or broken, not that someone's pull request is failing.

## Images

| Image | Base | Tag | Platforms |
|---|---|---|---|
| `ghcr.io/greenblacked/ci-node22` | `node:22-bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-node24` | `node:24-bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-python314` | `python:3.14-slim-trixie` | `trixie-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-python313` | `python:3.13-slim-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-python312` | `python:3.12-slim-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-go` | `golang:1-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-rust` | `rust:1-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-ruby40` | `ruby:4.0-slim-trixie` | `trixie-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-ruby34` | `ruby:3.4-slim-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-java25` | `eclipse-temurin:25-jdk-noble` | `noble-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-java21` | `eclipse-temurin:21-jdk-noble` | `noble-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-java17` | `eclipse-temurin:17-jdk-noble` | `noble-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-php85` | `php:8.5-cli-trixie` | `trixie-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-php84` | `php:8.4-cli-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-dotnet10` | `mcr.microsoft.com/dotnet/sdk:10.0-noble` | `noble-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-dotnet9` ([deprecated](#deprecated-ci-dotnet8-and-ci-dotnet9)) | `mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-dotnet8` ([deprecated](#deprecated-ci-dotnet8-and-ci-dotnet9)) | `mcr.microsoft.com/dotnet/sdk:8.0-bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-tools` | `debian:bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-cloud` | `debian:bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-security` | `debian:bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-db` | `debian:bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |

These are **CI images**, used as GitHub Actions container jobs — not as `FROM` bases for
application Dockerfiles. Every image ships the same shared baseline: bash, git, CA certificates,
curl, tar, gzip, unzip, xz, zstd, jq, and the OpenSSH client. On top of that:

- **`ci-node22`** — Node.js 22, npm, and Playwright's system libraries (Chromium only, no browser
  binaries; see below).
- **`ci-node24`** — the same image on Node.js 24, for repositories that have moved to the newer
  LTS line or that test against both in a matrix.
- **`ci-python314`** — Python 3.14 and pip, on Debian Trixie. Otherwise identical to
  `ci-python313`, including the absent compiler toolchain.
- **`ci-python313`** — Python 3.13 and pip. No compiler toolchain: projects that build native
  wheels add `build-essential` in their own workflow, for the same reason browsers are not baked
  into `ci-node22`.
- **`ci-python312`** — the same image on Python 3.12, for the still-common case of a library that
  supports both and tests each in a matrix.
- **`ci-go`** — the current stable Go toolchain (non-slim upstream, so cgo's C toolchain is
  included). Deliberately not named for a Go version — see below.
- **`ci-rust`** — the current stable Rust toolchain, plus the `rustfmt` and `clippy` components CI
  lints with (non-slim upstream, so the C toolchain the linker needs is included). Deliberately not
  named for a Rust version — see below.
- **`ci-ruby40`** — Ruby 4.0, RubyGems, and Bundler, on Debian Trixie. Otherwise identical to
  `ci-ruby34`.
- **`ci-ruby34`** — Ruby 3.4, RubyGems, and Bundler. No compiler toolchain: projects with gems
  that build native extensions add `build-essential` in their own workflow, same as `ci-python313`.
- **`ci-java25`** — the Temurin JDK 25, the newest LTS. Same no-Maven, no-Gradle reasoning as
  `ci-java21`, below.
- **`ci-java21`** — the Temurin JDK 21. No Maven and no Gradle: both ship a wrapper (`mvnw`,
  `gradlew`) that projects commit and that pins the exact build version, so a second copy here
  would be ignored or fight the wrapper.
- **`ci-java17`** — the Temurin JDK 17, the previous LTS, which a large amount of production Java
  is still built on. Same no-Maven, no-Gradle reasoning as `ci-java21`.
- **`ci-php85`** — PHP 8.5 CLI plus the same pinned Composer as `ci-php84`, on Debian Trixie.
- **`ci-php84`** — PHP 8.4 CLI plus Composer. Composer is the one package manager not shipped by
  its upstream runtime image, so it is installed here — pinned by version *and* SHA-256, and
  fetched from the GitHub release rather than `getcomposer.org`, which is not reachable from every
  build network.
- **`ci-dotnet10`** — the .NET SDK 10.0, the current LTS release, on Ubuntu Noble. No global
  tools: those are pinned per project in `.config/dotnet-tools.json` and restored by the project's
  own workflow.
- **`ci-dotnet9`** — the .NET SDK 9.0 (STS). **Deprecated, retiring after 2026-11-10** — see
  [below](#deprecated-ci-dotnet8-and-ci-dotnet9).
- **`ci-dotnet8`** — the .NET SDK 8.0 (the previous LTS). **Deprecated, retiring after
  2026-11-10** — see [below](#deprecated-ci-dotnet8-and-ci-dotnet9).
- **`ci-tools`** — infra/deploy tooling as pinned upstream release binaries: Terraform, kubectl,
  the AWS CLI v2, and the Docker *client* (no daemon — it talks to the host's socket or a
  `docker:dind` service). Versions are pinned via `ARG`s in
  [ci-tools/Dockerfile.ci](ci-tools/Dockerfile.ci); a bump is a one-line PR that CI revalidates.
- **`ci-cloud`** — the GCP and Azure counterpart to `ci-tools`: the `gcloud` CLI, the Azure CLI,
  and the same pinned `kubectl`. Split by cloud rather than bundled into one image because most
  repositories deploy to exactly one, and these SDKs are large enough that carrying two unused
  ones is a real cost on every job. The Azure CLI comes from Microsoft's GPG-signed apt
  repository; `gcloud` is a pinned tarball that Google publishes no checksum for, which is
  labelled as such in [ci-cloud/Dockerfile.ci](ci-cloud/Dockerfile.ci).
- **`ci-security`** — the supply-chain toolbox this repository's own pipeline uses: `trivy`,
  `syft`, `grype`, `cosign`, and `gitleaks`, so a consumer can reproduce the scans that gate here.
  Every binary is pinned *and* checksum-verified — all five projects publish sums, so unlike
  `ci-tools` there is no unverified download in it. No vulnerability database is baked in: `trivy`
  and `grype` fetch and cache their own, and a baked snapshot would be stale on publish in a way
  nobody downstream could see.
- **`ci-db`** — database clients and migration tooling for integration jobs: `psql`, `mysql`,
  `redis-cli`, and pinned `golang-migrate`. Clients only — a job needing a live database declares
  it as a `services:` container, which Actions health-checks and tears down; a server baked in here
  would be a second, unsupervised copy.

**Why `ci-go` and `ci-rust` carry no version, when every other image does.** The versioned names
are not decoration — they are the choice a consumer makes between *parallel supported lines*. Node
22 and 24, Python 3.12 to 3.14, Java 17, 21 and 25, PHP 8.4 and 8.5, Ruby 3.4 and 4.0, and .NET 8
to 10 are all patched independently by upstream, so `ci-python313` is not "behind" `ci-python314`
any more than `ci-node22` is behind 24; you pick the line your project targets.

Go and Rust have no such lines. Rust patches exactly one version — the current stable — and never
backports. Go patches only the two newest minors. Both promise that code building on one 1.x builds
on later 1.x. So a minor in the name offers a choice upstream does not provide, and guarantees the
image falls out of support on a fixed schedule. This repository proved that the hard way: the image
formerly called `ci-rust185` sat on Rust 1.85 while stable reached 1.97 — twelve unsupported
releases behind — because the name made the staleness look intentional. Tracking `rust:1-bookworm`
and `golang:1-bookworm` fixes it permanently rather than restarting the same countdown.

Projects that genuinely need an exact toolchain already have the right mechanism: a
`rust-toolchain.toml`, or the `toolchain` directive in `go.mod`. Both work inside these images.

Some of these break a pattern worth naming explicitly:

- **The Java images and `ci-dotnet10` are not Debian.** Temurin publishes no Debian tag — only
  Ubuntu and Alpine — and installing a JDK onto a Debian slim image would pin us to whatever Debian
  ships. Microsoft likewise publishes no Debian SDK image for .NET 10; its Linux default moved to
  Ubuntu. All of them are built on Noble and carry their own **`noble-v1`** version line. The
  version tag is per image, so this costs nothing structurally.
- **The newest Debian-based images are Trixie, not Bookworm.** `ci-python314`, `ci-php85` and
  `ci-ruby40` start on Debian 13 and carry **`trixie-v1`**. Debian 12 Bookworm's regular security
  support has ended and it is on reduced Debian LTS coverage, so starting a brand-new image on it
  would be migration debt from day one. The existing Bookworm images are unchanged by this.
- **The .NET images do not come from Docker Hub.** Microsoft publishes .NET only to
  `mcr.microsoft.com`. They are still mirrored, so builds depend on one registry rather than two.

None of them contains project dependencies, application source, credentials, repository secrets,
or project-specific build tools. Dependencies stay controlled by each consuming repository's own
lockfile — `package-lock.json`, `requirements.txt`, `go.sum`, `Cargo.lock`, `Gemfile.lock` — and
are installed by that repo's own workflow. Each image's `test.sh` asserts this, so a dependency
that creeps in fails the build.

For `ci-node22` specifically that also rules out Next.js and Wrangler. Wrangler in particular is a
locked devDependency, so `npm run deploy:artifact` uses the consuming repository's exact version
rather than one frozen into this image.

There is intentionally **no runtime image**. Purr.pet deploys to Cloudflare Workers, which runs
V8 isolates and never pulls a container image, so a runtime base would have no consumer. If a
container target is ever added (Cloudflare Containers, Fly, Kubernetes), that is when to add one.

### Deprecated: `ci-dotnet8` and `ci-dotnet9`

.NET 8 (LTS) and .NET 9 (STS) both reach Microsoft's end of support on **2026-11-10**. After that
date neither receives security fixes upstream, so rebuilding these images weekly would only keep
producing fresh digests of an unpatched runtime.

- **Move to `ci-dotnet10`** (`ghcr.io/greenblacked/ci-dotnet10:noble-v1`), the current LTS line.
  It is Ubuntu Noble rather than Debian Bookworm, so a job that installs extra packages with
  `apt-get` should check that their names still resolve.
- **Both images will be retired after 2026-11-10** — removed from this repository's build, so they
  stop being rebuilt and re-scanned. Until then they are built, scanned and published as normal.
- Retiring an image does not delete its published package (see
  [Tags and rebuilds](#tags-and-rebuilds)); deleting the GHCR packages is a separate decision for
  the repository owner.

## Using it

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    container:
      image: ghcr.io/greenblacked/ci-node22:bookworm-v1
    defaults:
      run:
        shell: bash        # GitHub defaults container commands to sh
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: npm run check
```

No `credentials:` and no `packages: read` — the package is public, so the pull is anonymous.

`actions/setup-node` is not needed — Node is already in the image. `runs-on` is only the host VM
that provides the Docker daemon; your steps execute inside the container, so the host's tooling is
never used.

In protected deployment jobs, pin by digest instead of by tag:

```yaml
    container:
      image: ghcr.io/greenblacked/ci-node22@sha256:...
```

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
manually dispatched run always covers all of them.

### Locally

The tag is multi-arch, so this runs natively on both Apple Silicon and x86 — no `--platform` flag
and no emulation:

```bash
docker run --rm -it -v "$PWD:/workspace" ghcr.io/greenblacked/ci-node22:bookworm-v1 bash
```

Useful for reproducing a CI failure with the exact toolchain the runner used. Both published
architectures are tested natively; to reproduce an amd64-specific failure from an Apple Silicon
machine, use `--platform linux/amd64`, which is emulated and slower.

### Building and testing an image locally

Editing a `Dockerfile.ci` or a `test.sh`? The [Makefile](Makefile) runs the same build-then-smoke-test
loop a PR does — from the upstream base, so no `ghcr.io` login — minus the registry writes and Trivy
scans that stay CI's job:

```bash
make list                     # one image per line: ci-cloud, ci-db, ci-dotnet8, ...
make check IMAGE=ci-rust   # build ci-rust:test, then run ci-rust/test.sh against it
make check-all                # every image
```

`build` and `test` are separate targets (`make build IMAGE=…`, `make test IMAGE=…`); `PLATFORM=linux/amd64`
cross-builds under emulation, and `TAG=` overrides the local `:test` tag. CI remains the source of
truth — it builds both architectures natively and enforces the vulnerability and secret gates the
Makefile does not.

`make lint` runs the CI lint job's exact battery — shellcheck, hadolint and actionlint on the same
pinned versions CI uses, the `images.json` cross-check, and a zizmor workflow audit. Engines are
downloaded once as checksum-verified release binaries into a git-ignored `.lint-cache/`. Running it
before opening a PR saves a round trip, because the `lint` job is the first thing that fails.

## Running Playwright tests

The image ships Playwright's **system libraries but no browser binaries**. Browsers are
version-locked to the `playwright` package in your lockfile, so baking them here would pin every
consuming repo to this image's Playwright version and break the moment one bumped it.

Install the browser your lockfile asks for — no `--with-deps`, and no root needed, because the
libraries are already present:

```yaml
      - run: npm ci
      - run: npx playwright install chromium
      - run: npx playwright test
```

Cache the browser download to keep this cheap:

```yaml
      - uses: actions/cache@v4
        with:
          path: ~/.cache/ms-playwright
          key: playwright-${{ hashFiles('package-lock.json') }}
```

The library set is pinned via the `PLAYWRIGHT_VERSION` build arg in
[ci-node22/Dockerfile.ci](ci-node22/Dockerfile.ci). It only determines which libraries get
installed — it does not constrain the Playwright version consumers run. These libraries are why
the image is ~660MB rather than ~240MB.

**Chromium only.** The image runs `playwright install-deps chromium`, so only Chromium's system
libraries are present — WebKit's and Firefox's (`libenchant-2-2`, `libwoff1`, `libgstreamer1.0-0`,
…) are not. `npx playwright install firefox` will download the browser, but it is not expected to
launch. If a project needs those browsers, add their libraries to the Dockerfile rather than
reaching for `--with-deps` in CI, which requires root.

Headless Chromium is verified to launch on **both** architectures. Headed mode is untested; `xvfb`
is present, but GTK is not, so assume headless.

## Using the tool images

`ci-cloud`, `ci-security` and `ci-db` are not language runtimes, so they are used a little
differently.

`ci-security` carries the same scanners this repository's own pipeline runs, which makes it useful
when you want them inside a container job rather than as marketplace actions:

```yaml
    container: ghcr.io/greenblacked/ci-security:bookworm-v1
    steps:
      - uses: actions/checkout@v5
      - run: trivy fs --exit-code 1 --severity HIGH,CRITICAL .
      - run: syft . -o cyclonedx-json=sbom.json
      - run: gitleaks detect --source . --redact
```

Note it ships **no** vulnerability database: `trivy` and `grype` each fetch and cache their own on
first run, so a baked-in snapshot cannot silently go stale. Budget for that download, or cache
`~/.cache/trivy` between runs.

`ci-db` carries clients only. Pair it with a `services:` container, which Actions health-checks and
tears down for you:

```yaml
    container: ghcr.io/greenblacked/ci-db:bookworm-v1
    services:
      postgres:
        image: postgres:17
        env: { POSTGRES_PASSWORD: postgres }
        options: >-
          --health-cmd pg_isready --health-interval 10s --health-retries 5
    steps:
      - uses: actions/checkout@v5
      - run: migrate -path ./migrations -database "$DATABASE_URL" up
        env:
          DATABASE_URL: postgres://postgres:postgres@postgres:5432/postgres?sslmode=disable
```

`ci-cloud` is the GCP/Azure counterpart to `ci-tools`. Authenticate with the relevant OIDC login
action first — the image deliberately contains no credentials, and its smoke test asserts that.

## Visibility and authentication

**The package is public.** Consuming repositories need no `credentials:`, no `packages: read`
permission, and no personal access token. Pulling works anonymously, anywhere:

```bash
docker pull ghcr.io/greenblacked/ci-node22:bookworm-v1
```

This is deliberate. The image is Debian, Node, and open-source tooling — there is nothing
proprietary in it, and `test.sh` enforces that no application source, dependencies, or
credentials are ever baked in. Making it private would buy nothing and cost a manual access grant
for every consuming repository, forever.

> **One-time manual step:** GHCR packages are created **private**, and visibility cannot be
> changed by the workflow — `GITHUB_TOKEN` lacks the permission. After the first successful push:
> package page → *Package settings* → *Change visibility* → **Public**. Do this for every `ci-*`
> image (`ci-node22`, `ci-node24`, `ci-python314`, `ci-python313`, `ci-python312`, `ci-go`,
> `ci-rust`, `ci-ruby40`, `ci-ruby34`, `ci-java25`, `ci-java21`, `ci-java17`, `ci-php85`,
> `ci-php84`, `ci-dotnet10`, `ci-dotnet9`, `ci-dotnet8`, `ci-tools`, `ci-cloud`, `ci-security`,
> `ci-db`) and every
> `mirror-*` package.
> Until then, pulls from other repositories fail with `denied`.

Publishing still authenticates, and always will: writing to any registry requires a bearer token
regardless of visibility. That is what the `docker/login-action` step plus `packages: write` in
[the workflow](.github/workflows/build-and-push.yml) is for.

Why authentication is not automatic, since this is a common misconception: GitHub Actions does not
run as you. Each run gets an ephemeral `GITHUB_TOKEN` belonging to `github-actions[bot]`, scoped
to the one repository it runs in — it carries none of your account's access, so "both repos are
mine" grants nothing. And `greenblacked` is a personal account (`"type": "User"`), not an
organization, so org-scoped conveniences like `internal` package visibility do not exist here.
GHCR is an ordinary OCI registry: it sees an HTTPS request for a blob, with no GitHub session or
repository identity attached, and the only thing that identifies the caller is the bearer token.

If you ever do make a package private again, each consuming repository must be granted access by
hand: package page → *Package settings* → *Manage Actions access* → *Add repository* → role
**Read**. That grant covers GitHub Actions only; local `docker pull` would then need a classic PAT
with `read:packages`.

## Mirrored upstream base

The workflow copies the upstream base into `ghcr.io` before building:

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
`digests.json` above — so "were we affected by an upstream compromise during window X" is
answerable later without a rebuild.

This is deliberately scoped to the mirror boundary only. The Dockerfiles' `ARG BASE_IMAGE`
defaults (`python:3.13`, `node:22`, `golang:1`, …) stay tag-based on purpose — that's what lets
Dependabot propose base bumps and the weekly rebuild pick up upstream patches — freezing those to
a digest would break the update mechanism this repo depends on.

Make each `mirror-*` package public along with its `ci-*` image. They are byte-identical copies of
images already public on Docker Hub, so privacy buys nothing — and making them public removes any
question of whether the build jobs can pull them. If one is left private and a build fails to pull
the mirror, grant this repository Read on the package via *Manage Actions access*.

Pull requests never touch the mirrors: PR builds use the upstream base directly, so a PR run
cannot mutate registry state — and the first PR adding a new image does not need its mirror to
exist yet.

## Tags and rebuilds

- **`bookworm-v1`** is a rolling contract line, and so are **`trixie-v1`** and **`noble-v1`** —
  each image carries exactly one, per the [table above](#images). The weekly rebuild moves it to a
  fresh digest carrying distribution security updates, plus whatever the upstream runtime base
  picked up. It is bumped to `v2` only when the *contents* of the image change — a tool added or
  removed. Determinism in production comes from pinning a digest, not from the tag.
  - For `ci-rust` and `ci-go` the line is rolling in one extra respect: the **language toolchain
    minor moves too**, because those images track `rust:1-bookworm` and `golang:1-bookworm`
    ([why](#images)). That is a deliberate exception to "contents change ⇒ bump to v2" — under the
    strict reading every upstream Rust release would need a new tag, which would make the contract
    line meaningless for exactly the two images whose upstreams have no support lines. The
    guarantee those two carry is *current stable of a 1.x-compatible language*, not a fixed minor.
    If you need a fixed minor, pin a digest, or pin the toolchain per project with a
    `rust-toolchain.toml` or a `toolchain` directive in `go.mod`.
- **`latest`** exists for testing. Never use it in a protected deployment job.
- **Renamed or removed images keep their old package.** GHCR does not delete a package when this
  repository stops building it, and nothing in the pipeline can: the package simply drops out of
  the weekly rebuild and the Trivy re-scan while staying published and pullable. It then quietly
  accumulates unpatched CVEs, and a consumer still pointing at it sees a working pull and no
  signal at all. **Deleting the old package is therefore part of a rename, not an optional
  tidy-up.** `ci-rust185` and `ci-go125` were retired this way and should be deleted from the
  package settings.
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

## Tests and security scanning

Nothing is pushed until the image has been built, smoke-tested, and scanned. Verification is
CI-driven: open a PR and the pipeline runs the whole stack; a green PR run is the pre-merge proof.

Each `<image>/test.sh` asserts every tool the image promises is present
(`--no-install-recommends` is exactly how one silently goes missing), that TLS verification
actually works, and that nothing project-specific — dependencies, credentials, state — is baked
in.

Trivy runs five scans on every build, per architecture. All reports are printed to the log,
attached to the job summary, and uploaded as a **`security-report-<image>-<arch>` artifact**
(retained 90 days), including on failed builds:

- **Vulnerability scan** — full report at every severity, and **a gate that blocks the push** on
  fixable HIGH/CRITICAL in the **Debian layer** only. That scope is deliberate:
  - Debian findings are actionable — `apt` pulls the patched package on the next rebuild.
  - `ignore-unfixed` keeps it honest: red always means a rebuild picks up a fix, rather than
    blocking on a CVE with no patch available.
  - **Library findings do not gate.** They are the runtime's own bundled dependencies (npm's
    `picomatch`, `sigstore`, …) shipped inside the upstream image, not fixable from this repo.
    Gating on them would block every push on someone else's release schedule. They are reported,
    not enforced.
- **Secret scan** — **gates at any severity**. A baked-in credential in a public CI image is
  always fixable from this repo, so unlike library vulns there is no excuse for shipping one.
- **Misconfiguration scan** — lints the Dockerfile's build instructions (missing `USER`, `ADD` vs
  `COPY`, …). Best-practice guidance rather than exploitable findings, so it is **reported, not
  gating** — the gates stay reserved for real, fixable security problems.
- **License scan** — the license of every OS package and bundled library in the image. **Reported,
  not gating**: a copyleft finding in Debian's own packages is information a consumer may need, not
  something fixable from here.
- **SBOM** — a CycloneDX bill of materials per image and architecture
  (`sbom-<image>-<arch>.cdx.json`, in the same artifact). This is what lets a consumer answer *"was
  I affected by X"* months later without rebuilding or re-scanning the image.

The vulnerability scan is also emitted as **SARIF and uploaded to the repository's Security tab**,
under a `<image>-<arch>` category, so findings are browsable and diffable over time rather than
buried in a build log. The upload is `continue-on-error` — code scanning must never be the reason
an image fails to publish.

**Its scope is deliberately wider than the gate's, so expect this view to be non-empty.** The gate
stays narrow on purpose (below); the SARIF exists to record what the gate lets through rather than
duplicate what it blocks:

- **No `ignore-unfixed`.** On an image whose build just ran `apt-get upgrade`, "fixed" and
  "already applied" are close to the same set — a fixed-only report on a freshly rebuilt image is
  close to a guarantee of nothing. What is left is overwhelmingly *unfixed* HIGH/CRITICAL CVEs,
  which is exactly the accepted risk worth a standing record.
- **No `vuln-type: os`**, so library findings are included too — the runtime's own bundled `pip`,
  `npm` and `gem` packages baked into the upstream image. They still don't gate, for the same
  reason as always (not fixable from this repo), but a consumer of the image has every reason to
  want to know what CVEs those bundled versions carry.
- **Severity stays HIGH,CRITICAL**, via `limit-severities-for-sarif: true` alongside `severity:`.
  Without that flag trivy-action silently ignores `severity:` for SARIF output and ships every
  severity, UNKNOWN and LOW included — see the comment at the step itself, and
  [ADR 0003](docs/adr/0003-gates-vs-reports.md) for why that flag exists at all.

So *Security → Code scanning* is where you look for what this repo has decided is safe to ship
without blocking: unfixed OS CVEs and library CVEs at HIGH/CRITICAL, browsable and diffable across
builds. It is accepted risk, not a build failure — nothing here means the pipeline is broken. For
the exhaustive picture (every severity, every scanner, unfixed and fixed alike) go to the job
summary or the `security-report-<image>-<arch>` artifact, which run with no filters at all.

**A second opinion from OSV.** After both architectures build, a separate `osv` job runs
[osv-scanner](https://github.com/google/osv-scanner) over the CycloneDX SBOM the build already
produced — no second image scan — and uploads the result to the Security tab under its own
`osv-<image>-<arch>` category, next to Trivy's. OSV aggregates the Debian and Ubuntu security
trackers alongside the npm, PyPI, RubyGems and Go advisories, so it is a different database
looking at the same packages. **Reported, not gating**, and it carries every severity OSV
reports, so expect it to be the larger of the two views.

Two things about it are less obvious than they look:

- **It fails when it could not look.** Findings are success. A scan that did not complete — the
  OSV database unreachable, no packages read from the SBOM, the binary not running — turns the
  job red, and its SARIF is deleted rather than uploaded. osv-scanner writes a valid, zero-result
  SARIF even when it could not reach its database; uploading that would be an empty report posing
  as a clean one. Being its own job, an outage there never holds up a publish.
- **The SBOM is normalised first.** As Trivy writes it, it matches nothing in OSV's Debian data:
  the purl says `distro=debian-12.15` where OSV files under `Debian:12`, and it names binary
  packages (`libc6`) where OSV keys by source (`glibc`). `scripts/osv-scan-sbom.sh` rewrites a
  copy from the source-package properties Trivy records; on `debian:bookworm-slim` that is the
  difference between 0 findings and 109. The SBOM artifact itself is untouched.

```bash
./scripts/osv-scan-sbom.sh sbom-ci-tools-amd64.cdx.json osv.sarif   # the same scan, locally
```

### Verifying a signature

Every published manifest list is signed with keyless cosign — no key to distribute, no key to
leak. The identity in the certificate is the workflow that built it, and checking that identity is
the whole point: a signature you never verify protects nobody, and until now this README did not
say how.

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp \
    '^https://github\.com/greenblacked/github-base-images/\.github/workflows/build-image\.yml@refs/heads/main$' \
  ghcr.io/greenblacked/ci-tools:bookworm-v1
```

**Do not drop the identity flags.** `cosign verify` without them checks only that *somebody*
signed the image, which any attacker with a Sigstore account can also do. The pair above is what
ties the artifact to this repository's `main`.

The identity is `build-image.yml`, not `build-and-push.yml`. Signing happens inside the reusable
workflow, and a reusable workflow signs under its own path — a common surprise, and the usual
reason a first `cosign verify` fails. If yours does, print what the signature actually claims
rather than guessing:

```bash
cosign verify --insecure-ignore-tlog=false \
  --certificate-identity-regexp '.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/greenblacked/ci-tools:bookworm-v1 2>&1 | head
```

That accepts any identity, so it is a diagnostic, **not** a verification — never leave it in a
pipeline.

Verification belongs in the job that consumes the image, not only in a README. Pin the digest from
`digests.json`, verify it, then run it: a tag can move, and a digest that was signed last week is
still the digest that was signed.

The pipeline runs this same check on itself. Straight after signing, the merge job verifies the
signature under exactly the identity above and confirms the SBOM and provenance attestations are
on the index (`scripts/check-published.sh --ref`, the same code as the
[post-publish audit](.github/workflows/published-audit.yml)). A signature that stops verifying —
a renamed workflow, a changed ref — fails the run that caused it, rather than surfacing from the
weekly audit. A check that could not run fails too, with its own message; it is never read as a
pass.

#### Or with the GitHub CLI

Each published index also carries a **GitHub build provenance attestation**, generated by
[`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance) in the
same job that runs cosign. It is independent of the cosign signature — a second verification
path, not a replacement:

```bash
gh attestation verify oci://ghcr.io/greenblacked/ci-tools:bookworm-v1 \
  --repo greenblacked/github-base-images \
  --cert-identity https://github.com/greenblacked/github-base-images/.github/workflows/build-image.yml@refs/heads/main
```

The identity is the same as cosign's, for the same reason: the attestation is signed inside the
reusable workflow. `--repo` alone would accept an attestation from *any* workflow in this
repository; `--cert-identity` pins it to `build-image.yml` on `main`. The pipeline runs this
exact command against every index it attests and fails if it does not verify.

### Attestations

Published images carry an **SBOM and provenance attestation** attached to the artifact itself, not
just to a build artifact that expires after 90 days. These are the `unknown/unknown` entries in:

```bash
docker buildx imagetools inspect ghcr.io/greenblacked/ci-ruby34:bookworm-v1
```

`sbom: true` and `provenance: mode=max` are set on the push step only — the test build uses the
docker exporter via `load:`, which cannot carry attestations. `imagetools create` preserves them
into the final multi-arch index.

The GitHub attestation above is a third, separate record: SLSA build provenance for the index
digest, signed through Sigstore with the workflow's OIDC identity, stored with GitHub's attestation
API and also pushed to GHCR next to the image. It adds to the buildx attestations and the cosign
signature; neither was changed.

On SLSA, precisely: GitHub describes artifact attestations on their own as meeting SLSA v1.0
**Build Level 2**, and notes that generating them in a reusable workflow *can* provide the
isolation **Build Level 3** asks for. Signing here does happen in a reusable workflow
(`build-image.yml`), but that workflow lives in the same repository as its caller and is
changed through the same pull requests, so it is not the separately controlled builder that
argument assumes. This repository makes no SLSA level claim beyond what the attestations
themselves state.

### Pin drift

Most of this repository's supply chain is watched by something: Dependabot tracks the action pins
and each Dockerfile's `ARG BASE_IMAGE`, and the weekly rebuild plus the Trivy gate cover the OS
packages. Its config carries a seven-day `cooldown` on every ecosystem — nothing is adopted the day
it ships, since the window between publication and discovery is exactly when a same-day bump would
pull in a compromised release — and one `groups` rule for `github/codeql-action`, whose `init`,
`analyze` and `upload-sarif` subpaths are one action on one SHA. Without the grouping Dependabot
opens a PR per subpath, and since CodeQL rejects `init` and `analyze` on different versions, two of
the three fail by construction while the third passes as a third of a change. The tools installed as pinned release binaries — Terraform, kubectl, the AWS CLI, the
Docker client, gcloud, Composer, Playwright, the five scanners in `ci-security`, and the
osv-scanner binary the pipeline itself runs — were the gap:
nothing read them, so they moved only when a human remembered. An audit found six behind at once.

[pin-drift.yml](.github/workflows/pin-drift.yml) closes that gap. Weekly, it compares every pinned
version against the version its vendor currently ships and maintains **one** tracking issue —
opened when something falls behind, updated while it stays behind, closed automatically once every
pin is current.

It reports rather than gates. Drift is not a broken build; it is a bump someone should make
deliberately, with a fresh checksum, through the normal PR path. Failing builds over it would just
teach people to ignore a permanently red repository.

Two cautions when acting on that issue. It is only as fresh as its last weekly run, so re-dispatch
the workflow before working from the table — more than once a bump has been prepared against a
version already superseded. And `hadolint-action` bundles the hadolint binary, so its version is
coupled to `HADOLINT_VERSION` in `scripts/lint.sh`; nothing enforces that, no check can see it, and
a Dependabot PR moving only the action is green while putting local and CI on different linters.
`lint.sh` carries a comment above the pin recording the mapping.

```bash
./scripts/check-pins.sh              # the same check, locally
```

### Repository security checks

[security.yml](.github/workflows/security.yml) scans the **repository**, where `build-and-push.yml`
scans the **images**. That is a different threat model: anyone who can influence a workflow file
controls every image this repo publishes, without touching a Dockerfile. It is a separate workflow
so a finding can never block an image build, and so it still runs on weeks when no image directory
changed — `build-and-push.yml` is path-filtered, this is not.

- **Repository secret scan** — Trivy over the working tree, covering workflows, docs, and the
  Makefile, none of which the image scan can see (nothing is `COPY`ed in). **Gates**, on the same
  reasoning as the image secret gate.
- **Workflow security audit** — `zizmor` checks whether the workflows are *safe*: template
  injection through `${{ }}` into `run:` blocks, over-broad permissions, unpinned actions, cache
  poisoning. `actionlint` already checks they are *valid*; this is the other half. **Reported,
  not gating**, and it runs on zizmor's default policy — including `hash-pin`, which every
  action in this repo now satisfies: all `uses:` are pinned by commit SHA with the version in a
  trailing comment, a form Dependabot understands and maintains.
- **CodeQL (`actions`)** — overlaps `zizmor` on purpose. `zizmor` is a rules engine over the YAML;
  CodeQL does dataflow, following an untrusted value from a trigger through expressions into a
  sink, which catches injection paths a pattern matcher reads as safe. `actions` is the only
  language worth analysing here — the repo is shell, YAML and Dockerfiles, none of which CodeQL
  supports.
- **Git history secret scan** — `gitleaks` over the full history, which the working-tree scan
  cannot see. A credential committed and removed in a later commit is still fetchable by anyone
  who clones. **Reported, not gating**, and deliberately so: a history finding cannot be fixed by
  a commit — it needs a history rewrite *plus* rotation — so failing the build would block every
  unrelated change until that happened. Treat a hit as an incident, not a broken build.
- **Token permissions** — not a scan but the posture the scans check for. Every workflow declares
  `permissions: {}` at the top level and every job opts back in to exactly the scopes it needs, so
  a job added without a `permissions:` block gets nothing and fails loudly rather than inheriting
  the repository default. That matters most in the two build workflows, which are the ones holding
  `packages: write` and `id-token: write`.
- **Dependency review** — on pull requests only, GitHub's
  [dependency-review-action](https://github.com/actions/dependency-review-action) checks what the
  PR *adds* to the dependency graph — in this repository, mostly action versions — against the
  advisory database. **Gates** at `fail-on-severity: high`: the fix is always available here (do
  not merge that version), and a review that could not run at all fails rather than passes. The
  OpenSSF Scorecard lookup it would otherwise make for each changed dependency, against
  `api.deps.dev` and `api.securityscorecards.dev`, is switched off, so it talks only to GitHub.
- **OpenSSF Scorecard** — branch protection, token permissions, pinned dependencies, dangerous
  workflow patterns. Produces the score behind the README badge. Runs on `main` only, since several
  checks inspect repository settings rather than the tree.

Four of these publish SARIF to the Security tab — everything above except the git-history scan,
whose findings are deliberately kept out of a view people triage to empty, and dependency review,
whose verdict is the PR check itself. So *Security → Code
scanning* collects repository secrets, workflow findings, the CodeQL results and the Scorecard
result. Image vulnerabilities are uploaded there too, under their own `<image>-<arch>` and
`osv-<image>-<arch>` categories — but unlike these repository-level scans, those are expected to
be **non-empty** on a healthy build; see the notes above on why, and what it means when they are
not.

> **First run:** the Scorecard badge stays grey until the workflow has run once on `main` and
> published its results. Both badges track `main`, so they will not reflect a pull request.

## PR validation and linting

A PR runs the full per-image pipeline — build both architectures natively, smoke test, all five
Trivy scans, both gates, the OSV report — for **every image the `plan` job selects** (the changed ones, or all of them
when the pipeline itself changed), with every registry write skipped. Publishing (mirror push,
digest push, manifest tagging) happens only on `main`. A manually dispatched run from another
branch builds everything, upstream-only, with no registry writes.

A `lint` job runs first and cheaply, so a typo never spends runner minutes on multi-arch builds:
**hadolint** on every `*/Dockerfile.ci` (DL3008 is ignored inline — apt pins would go stale and
break the weekly rebuild, which is the actual update mechanism; DL3006 is ignored inline on the
`FROM ${BASE_IMAGE}` lines — the ARG default is tagged, hadolint just can't resolve it),
**actionlint** on the workflows,
and **shellcheck** on every `*/test.sh` (SC2016 is ignored per file — check strings are
deliberately single-quoted so they expand inside the container, not on the host).

**Dependabot** ([.github/dependabot.yml](.github/dependabot.yml)) keeps the workflow's action pins
and each image's base-image ref current with weekly PRs. Because PR validation runs the full
build/test/scan stack, a Dependabot bump arrives pre-verified — green means the updated base
already built, passed the smoke tests, and cleared both gates on both architectures.

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
Docker daemon, so the arm64
image could not be smoke-tested or scanned before publishing. arm64 runners are free for public
repositories, which makes the native path both faster and better tested.

Pinning a digest still works normally: pin the manifest-list digest from the run summary, and it
stays correct on both architectures.

## Adding another image

The image list lives in one place: [.github/images.json](.github/images.json), an array of
`{image, version, mirror, upstream}` entries. [build-and-push.yml](.github/workflows/build-and-push.yml)
reads it and calls the reusable per-image pipeline in
[build-image.yml](.github/workflows/build-image.yml) once per entry — there are no per-image
jobs to copy any more.

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

### Which images a run builds

A push or pull request builds **only the images whose directories changed** — a one-line fix to
`ci-ruby34` does not rebuild the other twenty images or move `latest` on them. Changing the
pipeline itself (either workflow file, or `images.json`) rebuilds everything, and the weekly
schedule and `workflow_dispatch` always rebuild everything — the rebuild is the security-update
mechanism and is never narrowed. Every ambiguous case (force-push, missing diff base) falls back
to the full list: over-building costs minutes, under-building leaves a stale published image
nobody notices. The chosen set is printed in the `plan` job's summary.

Each published index is also asserted to contain **both** platforms before the merge job goes
green — a one-architecture manifest is exactly the failure nobody notices until an Apple Silicon
machine pulls it.

### Future candidates

Java/JVM, .NET and PHP graduated from this list, alongside Rust and Ruby; `ci-cloud`,
`ci-security` and `ci-db` followed, along with second runtime versions for Node, Python, Java
and .NET.

Nothing is queued behind them, and the bar for the next one is **raised**, not unchanged: a
concrete consumer. That bar was applied loosely when the set grew to sixteen — the second runtime
versions in particular were added for matrix coverage that nobody had asked for yet. The five
added since (`ci-dotnet10`, `ci-java25`, `ci-python314`, `ci-php85`, `ci-ruby40`) are the next
supported line of runtimes already shipped here, not new kinds of image: they are where consumers
of the older lines move as those reach end of life, as `ci-dotnet8` and `ci-dotnet9` do next.

An image with no consumer is not free: it is two build jobs, nine Trivy scans per architecture on
every full rebuild, another base to keep current, and another set of pinned tools nothing tracks. The
marginal cost of *writing* one is a directory and two config entries; the marginal cost of
*owning* one is considerably higher, and that is the number that matters.

If an image here has no consumer, deleting it is a legitimate and expected change.

## Contributing and reporting problems

[CONTRIBUTING.md](CONTRIBUTING.md) covers the local loop and the pre-PR checks;
[SECURITY.md](SECURITY.md) covers how to report a vulnerability in a published image, and what is
in and out of scope.

For *why* it is built this way — why upstream bases are mirrored, why library vulnerabilities are
reported but do not gate, why builds are native rather than emulated, and why every action is
SHA-pinned — see the [architecture decision records](docs/adr/README.md).

## License

[MIT](LICENSE), and each image carries `org.opencontainers.image.licenses=MIT`.

That covers **this repository's** contents — the Dockerfiles, test scripts, workflow, and Makefile.
It says nothing about the software inside the published images: Debian and its packages, Node,
Python, Go, Rust, Ruby, PHP, .NET, Java, Terraform, kubectl, the AWS CLI, the Docker client, the
gcloud and Azure CLIs, the database clients, and the scanning tools in `ci-security` each ship
under their own upstream licenses, which travel with the image. If you need to audit those, start
from the `mirror-*` package for the base, the pinned versions in the relevant `Dockerfile.ci`, and
the CycloneDX SBOM published as a build artifact for every image and architecture.
