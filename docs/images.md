# Images

The detail behind each row of the [image catalog](../README.md#image-catalog) in the README: what
each image contains and why, how to use the less obvious ones, visibility, and how to run and build
them locally. How images are built and published is in [pipeline.md](pipeline.md); what is checked
before anything is pushed is in [security.md](security.md).

- [What every image contains](#what-every-image-contains)
- Runtimes: [Node.js](#nodejs), [Python](#python), [Go and Rust](#go-and-rust), [Ruby](#ruby),
  [Java](#java), [PHP](#php), [.NET SDK](#net-sdk)
- [Tool images](#tool-images): `ci-tools`, `ci-cloud`, `ci-security`, `ci-db`
- [Patterns worth naming](#patterns-worth-naming)
- [Image lifecycle](#image-lifecycle): new lines, deprecation, retirement
- [Running Playwright tests](#running-playwright-tests)
- [Using the tool images](#using-the-tool-images)
- [Visibility and authentication](#visibility-and-authentication)
- [Running an image locally](#running-an-image-locally)
- [Building and testing an image locally](#building-and-testing-an-image-locally)
- [Future candidates](#future-candidates)

## What every image contains

These are **CI images**, used as GitHub Actions container jobs — not as `FROM` bases for
application Dockerfiles. Every image ships the same shared baseline: bash, git, CA certificates,
curl, tar, gzip, unzip, xz, zstd, jq, and the OpenSSH client. The sections below list what each
one adds on top.

None of them contains project dependencies, application source, credentials, repository secrets,
or project-specific build tools. Dependencies stay controlled by each consuming repository's own
lockfile — `package-lock.json`, `requirements.txt`, `go.sum`, `Cargo.lock`, `Gemfile.lock` — and
are installed by that repo's own workflow. Each image's `test.sh` asserts this, so a dependency
that creeps in fails the build.

There is intentionally **no runtime image**. Purr.pet deploys to Cloudflare Workers, which runs
V8 isolates and never pulls a container image, so a runtime base would have no consumer. If a
container target is ever added (Cloudflare Containers, Fly, Kubernetes), that is when to add one.

## Runtimes

### Node.js

- **`ci-node24`** — the same image on Node.js 24, for repositories that have moved to the newer
  LTS line or that test against both in a matrix.
- **`ci-node22`** — Node.js 22, npm, and Playwright's system libraries (Chromium only, no browser
  binaries; see [Running Playwright tests](#running-playwright-tests)).

For the Node images, "no project-specific build tools" also rules out Next.js and Wrangler.
Wrangler in particular is a locked devDependency, so `npm run deploy:artifact` uses the consuming
repository's exact version rather than one frozen into the image.

`actions/setup-node` is not needed — Node is already in the image.

### Python

- **`ci-python314`** — Python 3.14 and pip, on Debian Trixie. Otherwise identical to
  `ci-python313`, including the absent compiler toolchain.
- **`ci-python313`** — Python 3.13 and pip. No compiler toolchain: projects that build native
  wheels add `build-essential` in their own workflow, for the same reason browsers are not baked
  into the Node images.
- **`ci-python312`** — the same image on Python 3.12, for the still-common case of a library that
  supports both and tests each in a matrix.

### Go and Rust

- **`ci-go`** — the current stable Go toolchain (non-slim upstream, so cgo's C toolchain is
  included). Deliberately not named for a Go version — see below.
- **`ci-rust`** — the current stable Rust toolchain, plus the `rustfmt` and `clippy` components CI
  lints with (non-slim upstream, so the C toolchain the linker needs is included). Deliberately not
  named for a Rust version — see below.

**Why `ci-go` and `ci-rust` carry no version, when every other image does.** The versioned names
are not decoration — they are the choice a consumer makes between *parallel supported lines*. The
Node.js, Python, Java, PHP, Ruby and .NET lines in the catalog are each patched independently by
upstream, so an image for an older Python line is not "behind" the newest one any more than Node
22 is behind 24; you pick the line your project targets.

Go and Rust have no such lines. Rust patches exactly one version — the current stable — and never
backports. Go patches only the two newest minors. Both promise that code building on one 1.x builds
on later 1.x. So a minor in the name offers a choice upstream does not provide, and guarantees the
image falls out of support on a fixed schedule. This repository proved that the hard way: the image
formerly called `ci-rust185` sat on Rust 1.85 while stable reached 1.97 — twelve unsupported
releases behind — because the name made the staleness look intentional. Tracking `rust:1-bookworm`
and `golang:1-bookworm` fixes it permanently rather than restarting the same countdown.

Projects that genuinely need an exact toolchain already have the right mechanism: a
`rust-toolchain.toml`, or the `toolchain` directive in `go.mod`. Both work inside these images.
What this means for the rolling tag is in [Tags and rebuilds](pipeline.md#tags-and-rebuilds).

### Ruby

- **`ci-ruby40`** — Ruby 4.0, RubyGems, and Bundler, on Debian Trixie. Otherwise identical to
  `ci-ruby34`.
- **`ci-ruby34`** — Ruby 3.4, RubyGems, and Bundler. No compiler toolchain: projects with gems
  that build native extensions add `build-essential` in their own workflow, same as the Python
  images.

### Java

- **`ci-java25`** — the Temurin JDK 25, the newest LTS. Same no-Maven, no-Gradle reasoning as
  `ci-java21`, below.
- **`ci-java21`** — the Temurin JDK 21. No Maven and no Gradle: both ship a wrapper (`mvnw`,
  `gradlew`) that projects commit and that pins the exact build version, so a second copy here
  would be ignored or fight the wrapper.
- **`ci-java17`** — the Temurin JDK 17, the previous LTS, which a large amount of production Java
  is still built on. Same no-Maven, no-Gradle reasoning as `ci-java21`.

### PHP

- **`ci-php85`** — PHP 8.5 CLI plus the same pinned Composer as `ci-php84`, on Debian Trixie.
- **`ci-php84`** — PHP 8.4 CLI plus Composer. Composer is the one package manager not shipped by
  its upstream runtime image, so it is installed here — pinned by version *and* SHA-256, and
  fetched from the GitHub release rather than `getcomposer.org`, which is not reachable from every
  build network.

### .NET SDK

- **`ci-dotnet10`** — the .NET SDK 10.0, the current LTS release, on Ubuntu Noble. No global
  tools: those are pinned per project in `.config/dotnet-tools.json` and restored by the project's
  own workflow.
- **`ci-dotnet9`** — the .NET SDK 9.0 (STS).
- **`ci-dotnet8`** — the .NET SDK 8.0 (the previous LTS).

Which images are deprecated, and when each retires, is in [Image lifecycle](#image-lifecycle) and
in the catalog.

## Tool images

- **`ci-tools`** — infra/deploy tooling as pinned upstream release binaries: Terraform, kubectl,
  the AWS CLI v2, and the Docker *client* (no daemon — it talks to the host's socket or a
  `docker:dind` service). Versions are pinned via `ARG`s in
  [ci-tools/Dockerfile.ci](../ci-tools/Dockerfile.ci); a bump is a one-line PR that CI revalidates.
- **`ci-cloud`** — the GCP and Azure counterpart to `ci-tools`: the `gcloud` CLI, the Azure CLI,
  and the same pinned `kubectl`. Split by cloud rather than bundled into one image because most
  repositories deploy to exactly one, and these SDKs are large enough that carrying two unused
  ones is a real cost on every job. The Azure CLI comes from Microsoft's GPG-signed apt
  repository; `gcloud` is a pinned tarball that Google publishes no checksum for, which is
  labelled as such in [ci-cloud/Dockerfile.ci](../ci-cloud/Dockerfile.ci).
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

Examples are in [Using the tool images](#using-the-tool-images).

## Patterns worth naming

Some of these images break a pattern worth naming explicitly:

- **Each image carries the distribution line it started on.** A new image starts on the newest
  Debian stable if upstream publishes the exact tag for it, otherwise on the newest Ubuntu LTS
  (only for Java and .NET, whose upstreams publish Ubuntu images); older releases of either are
  never used. Temurin publishes no Debian tag at all (only Ubuntu and Alpine), and Microsoft has
  published no Debian SDK image since .NET 10, so those lines land on Ubuntu unless that changes. Installing a JDK or an SDK onto a Debian
  slim image instead would replace an official, upstream-maintained build with one this
  repository maintains. Existing images never move, so `bookworm-v1`, `trixie-v1` and `noble-v1`
  coexist, and Ubuntu 26.04 adds `resolute-v1` with the first image built on it. The version tag
  is per image, so this costs nothing structurally.
- **Starting a new image on an older distribution would be migration debt from day one.** Debian
  12 Bookworm's regular security support has ended and it is on reduced Debian LTS coverage, so a
  brand-new image starts on Debian 13 Trixie (`trixie-v1`), the newest stable.
- **The .NET images do not come from Docker Hub.** Microsoft publishes .NET only to
  `mcr.microsoft.com`. They are still [mirrored](pipeline.md#mirrored-upstream-base), so builds
  depend on one registry rather than two.

[ADR 0005](adr/0005-new-images-current-distro-retire-at-eol.md) records the rule behind the first
two, and [ADR 0009](adr/0009-image-lifecycle.md) the newest-Ubuntu-LTS amendment.

## Image lifecycle

The catalog follows upstream's support lines without anyone tending it
([ADR 0009](adr/0009-image-lifecycle.md)). The daily
[image lifecycle workflow](../.github/workflows/image-lifecycle.yml) reads each runtime's support
dates from [endoflife.date](https://endoflife.date) and its tags from the upstream registry, and
opens a pull request for whatever is due. Each one merges itself when its checks are green, like
every other automated update ([Automatic updates](pipeline.md#automatic-updates)).

- **New lines are added.** When upstream ships a line newer than the newest image of its runtime,
  generally available and published for `linux/amd64` and `linux/arm64`, a pull request adds
  `ci-<runtime><version>`. Node.js only for even majors, once they are LTS; Java only for LTS
  releases; .NET for every release, STS included. It starts on the newest Debian stable if the
  exact upstream tag exists for it, else on the newest Ubuntu LTS (Java and .NET only), on the
  version line `<codename>-v1`; older distribution releases are never tried. A line that is GA
  but has no tag on either yet waits, and the daily run shows it as a notice. Older lines are
  never added, and nothing before its GA release.
- **Deprecation is announced 120 days ahead** of upstream end of support (the end of security
  fixes): the catalog row is marked with the date, and a notice goes into the README,
  [SECURITY.md](../SECURITY.md) and below.
- **Images retire after end of support**, and no sooner than 30 days after the notice: they leave
  the build, so they are no longer rebuilt or re-scanned. Their packages stay pullable until the
  owner deletes them; no workflow here deletes a package.
- **Closing one of these pull requests is a veto.** It is not reopened for the same change: an
  add closed unmerged is not proposed again for that tag, a retirement not for that date.
- **`ci-go`, `ci-rust` and the tool images are not part of this.** Go and Rust track current
  stable ([why](#go-and-rust)); the tool images have no runtime line.

**One step stays manual:** a new image's GHCR package is created private, and no workflow token
can make it public (GitHub has no API for package visibility). After the first publish of an added
image, make its package public as described in
[Visibility and authentication](#visibility-and-authentication). Until then pulls from other
repositories fail with `denied`, and the published-image audit reports the package as private.
The pull request that adds the image says so too.
<!-- lifecycle:status:begin -->

### Deprecated: `ci-dotnet8` and `ci-dotnet9`

.NET 8 and .NET 9 reach end of support upstream on **2026-11-10**. After that date they receive no
security fixes upstream, so rebuilding these images daily would only keep producing fresh digests
of an unpatched runtime.

- **Move to `ci-dotnet10`** (`ghcr.io/greenblacked/ci-dotnet10:noble-v1`). It is Ubuntu Noble
  rather than Debian Bookworm, so a job that installs extra packages with `apt-get` should check
  that their names still resolve.
- **Retired automatically after 2026-11-10**, and no sooner than 30 days after this notice: the
  image lifecycle workflow opens a pull request that removes them from the build, so they stop
  being rebuilt and re-scanned. Until then they are built, scanned and published as normal.
- Retiring an image does not delete its published package (see [Tags and
  rebuilds](pipeline.md#tags-and-rebuilds)); deleting the GHCR package is a separate decision for
  the repository owner.

<!-- lifecycle:status:end -->

## Running Playwright tests

The Node images ship Playwright's **system libraries but no browser binaries**.
Browsers are version-locked to the `playwright` package in your lockfile, so baking them here
would pin every consuming repo to this image's Playwright version and break the moment one bumped
it.

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

The library set is pinned via the `PLAYWRIGHT_VERSION` build arg in each Node image's
`Dockerfile.ci`, the same version in every one. It only determines which libraries get installed —
it does not constrain the Playwright version consumers run. These libraries are why
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

**The packages are public.** Consuming repositories need no `credentials:`, no `packages: read`
permission, and no personal access token. Pulling works anonymously, anywhere:

```bash
docker pull ghcr.io/greenblacked/ci-node22:bookworm-v1
```

This is deliberate. The images are Debian or Ubuntu, the language runtimes, and open-source
tooling — there is nothing proprietary in them, and `test.sh` enforces that no application source,
dependencies, or credentials are ever baked in. Making them private would buy nothing and cost a
manual access grant for every consuming repository, forever.

> **One-time manual step, for every new package:** GHCR packages are created **private**, and
> visibility cannot be changed by the workflow: `GITHUB_TOKEN` lacks the permission, and GitHub's
> REST API for packages has no endpoint that changes visibility at all (it lists, reads, deletes
> and restores). After the first successful push: package page → *Package settings* → *Change
> visibility* → **Public**. Do this for every `ci-*` image in the
> [catalog](../README.md#image-catalog), including each one the
> [image lifecycle](#image-lifecycle) adds, and every new `mirror-*` package (see [Mirrored upstream
> base](pipeline.md#mirrored-upstream-base) for why the mirrors can be public too). A new line of
> an existing runtime reuses its runtime's `mirror-*` package, so it needs only the `ci-*` one.
> Until then, pulls from other repositories fail with `denied`, and the published-image audit
> reports the package.

Publishing still authenticates, and always will: writing to any registry requires a bearer token
regardless of visibility. That is what the `docker/login-action` step plus `packages: write` in
[the workflow](../.github/workflows/build-and-push.yml) is for.

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

## Running an image locally

The tag is multi-arch, so this runs natively on both Apple Silicon and x86 — no `--platform` flag
and no emulation:

```bash
docker run --rm -it -v "$PWD:/workspace" ghcr.io/greenblacked/ci-node22:bookworm-v1 bash
```

Useful for reproducing a CI failure with the exact toolchain the runner used. Both published
architectures are tested natively; to reproduce an amd64-specific failure from an Apple Silicon
machine, use `--platform linux/amd64`, which is emulated and slower.

## Building and testing an image locally

Editing a `Dockerfile.ci` or a `test.sh`? The [Makefile](../Makefile) runs the same
build-then-smoke-test loop a PR does — from the upstream base, so no `ghcr.io` login — minus the
registry writes and Trivy scans that stay CI's job:

```bash
make list                     # one image per line: ci-cloud, ci-db, ...
make check IMAGE=ci-rust      # build ci-rust:test, then run ci-rust/test.sh against it
make check-all                # every image
```

`build` and `test` are separate targets (`make build IMAGE=…`, `make test IMAGE=…`);
`PLATFORM=linux/amd64` cross-builds under emulation, and `TAG=` overrides the local `:test` tag. CI
remains the source of truth — it builds both architectures natively and enforces the vulnerability
and secret gates the Makefile does not.

`make lint` runs the CI lint job's exact battery — shellcheck, hadolint and actionlint on the same
pinned versions CI uses, the `images.json` cross-check, the
[vulnerability exceptions](security.md#vulnerability-exceptions) check, and a zizmor workflow
audit. Engines are downloaded once as checksum-verified release binaries into a git-ignored
`.lint-cache/`. Running it before opening a PR saves a round trip, because the `lint` job is the
first thing that fails. [CONTRIBUTING.md](../CONTRIBUTING.md) has the rest of the local loop.

## Future candidates

Java/JVM, .NET and PHP graduated from this list, alongside Rust and Ruby; `ci-cloud`,
`ci-security` and `ci-db` followed, along with second runtime versions for Node, Python, Java
and .NET.

Nothing is queued behind them, and the bar for the next *kind* of image is **raised**, not
unchanged: a concrete consumer. That bar was applied loosely when the set grew to sixteen — the
second runtime versions in particular were added for matrix coverage that nobody had asked for
yet. The next supported line of a runtime already shipped here is different: it is where
consumers of the older lines move as those reach end of life, so the
[image lifecycle](#image-lifecycle) adds it on its own, and retires the old line after its end of
support.

An image with no consumer is not free: it is two build jobs, nine Trivy steps per architecture (the
five scan kinds) on every full rebuild, another base to keep current, and another set of pinned tools nothing tracks.
The marginal cost of *writing* one is a directory and two config entries; the marginal cost of
*owning* one is considerably higher, and that is the number that matters.

If an image here has no consumer, deleting it is a legitimate and expected change. The mechanics of
adding one by hand are in [CONTRIBUTING.md](../CONTRIBUTING.md#adding-another-image).
