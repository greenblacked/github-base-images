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
| `ghcr.io/greenblacked/ci-python313` | `python:3.13-slim-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-go125` | `golang:1.25-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-rust185` | `rust:1.85-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-ruby34` | `ruby:3.4-slim-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-java21` | `eclipse-temurin:21-jdk-noble` | `noble-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-php84` | `php:8.4-cli-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-dotnet9` | `mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-tools` | `debian:bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |

These are **CI images**, used as GitHub Actions container jobs — not as `FROM` bases for
application Dockerfiles. Every image ships the same shared baseline: bash, git, CA certificates,
curl, tar, gzip, unzip, xz, zstd, jq, and the OpenSSH client. On top of that:

- **`ci-node22`** — Node.js 22, npm, and Playwright's system libraries (Chromium only, no browser
  binaries; see below).
- **`ci-python313`** — Python 3.13 and pip. No compiler toolchain: projects that build native
  wheels add `build-essential` in their own workflow, for the same reason browsers are not baked
  into `ci-node22`.
- **`ci-go125`** — the Go 1.25 toolchain (non-slim upstream, so cgo's C toolchain is included).
- **`ci-rust185`** — the Rust 1.85 toolchain, plus the `rustfmt` and `clippy` components CI lints
  with (non-slim upstream, so the C toolchain the linker needs is included).
- **`ci-ruby34`** — Ruby 3.4, RubyGems, and Bundler. No compiler toolchain: projects with gems
  that build native extensions add `build-essential` in their own workflow, same as `ci-python313`.
- **`ci-java21`** — the Temurin JDK 21. No Maven and no Gradle: both ship a wrapper (`mvnw`,
  `gradlew`) that projects commit and that pins the exact build version, so a second copy here
  would be ignored or fight the wrapper.
- **`ci-php84`** — PHP 8.4 CLI plus Composer. Composer is the one package manager not shipped by
  its upstream runtime image, so it is installed here — pinned by version *and* SHA-256, and
  fetched from the GitHub release rather than `getcomposer.org`, which is not reachable from every
  build network.
- **`ci-dotnet9`** — the .NET SDK 9.0. No global tools: those are pinned per project in
  `.config/dotnet-tools.json` and restored by the project's own workflow.
- **`ci-tools`** — infra/deploy tooling as pinned upstream release binaries: Terraform, kubectl,
  the AWS CLI v2, and the Docker *client* (no daemon — it talks to the host's socket or a
  `docker:dind` service). Versions are pinned via `ARG`s in
  [ci-tools/Dockerfile.ci](ci-tools/Dockerfile.ci); a bump is a one-line PR that CI revalidates.

Two of these break a pattern worth naming explicitly:

- **`ci-java21` is not Bookworm.** Temurin publishes no Debian Bookworm tag — only Ubuntu and
  Alpine — and installing a JDK onto `debian:bookworm-slim` would pin us to whatever Debian ships
  (17, not 21). It is built on Noble and carries its own **`noble-v1`** version line. The version
  tag is per image, so this costs nothing structurally.
- **`ci-dotnet9` does not come from Docker Hub.** Microsoft publishes .NET only to
  `mcr.microsoft.com`. It is still mirrored, so builds depend on one registry rather than two.

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
make list                     # one image per line: ci-go125, ci-node22, ci-python313, ...
make check IMAGE=ci-rust185   # build ci-rust185:test, then run ci-rust185/test.sh against it
make check-all                # every image
```

`build` and `test` are separate targets (`make build IMAGE=…`, `make test IMAGE=…`); `PLATFORM=linux/amd64`
cross-builds under emulation, and `TAG=` overrides the local `:test` tag. CI remains the source of
truth — it builds both architectures natively and enforces the vulnerability and secret gates the
Makefile does not.

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
> image (`ci-node22`, `ci-python313`, `ci-go125`, `ci-rust185`, `ci-ruby34`, `ci-java21`,
> `ci-php84`, `ci-dotnet9`, `ci-tools`) and every
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
| `ghcr.io/greenblacked/mirror-python:3.13-slim-bookworm` | `python:3.13-slim-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-golang:1.25-bookworm` | `golang:1.25-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-rust:1.85-bookworm` | `rust:1.85-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-ruby:3.4-slim-bookworm` | `ruby:3.4-slim-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-debian:bookworm-slim` | `debian:bookworm-slim` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-temurin:21-jdk-noble` | `eclipse-temurin:21-jdk-noble` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-php:8.4-cli-bookworm` | `php:8.4-cli-bookworm` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-dotnet:9.0-bookworm-slim` | `mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim` (MCR) |

Builds then use the mirror, so they do not depend on Docker Hub availability or rate limits. The
Dockerfile takes a `BASE_IMAGE` build arg that defaults to upstream, so local builds still work
without authenticating to `ghcr.io`; CI overrides it with the mirror.

Make each `mirror-*` package public along with its `ci-*` image. They are byte-identical copies of
images already public on Docker Hub, so privacy buys nothing — and making them public removes any
question of whether the build jobs can pull them. If one is left private and a build fails to pull
the mirror, grant this repository Read on the package via *Manage Actions access*.

Pull requests never touch the mirrors: PR builds use the upstream base directly, so a PR run
cannot mutate registry state — and the first PR adding a new image does not need its mirror to
exist yet.

## Tags and rebuilds

- **`bookworm-v1`** is a rolling contract line. The weekly rebuild moves it to a fresh digest
  carrying Debian security updates, plus whatever the upstream runtime base picked up. It is
  bumped to `v2` only when the *contents* of the
  image change — a tool added or removed. Determinism in production comes from pinning a digest,
  not from the tag.
- **`latest`** exists for testing. Never use it in a protected deployment job.
- **`<commit-sha>`** identifies the exact build.

Every image rebuilds on every push to `main` touching any image directory, weekly on a schedule,
and on demand via *Run workflow*.

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

### Attestations

Published images carry an **SBOM and provenance attestation** attached to the artifact itself, not
just to a build artifact that expires after 90 days. These are the `unknown/unknown` entries in:

```bash
docker buildx imagetools inspect ghcr.io/greenblacked/ci-ruby34:bookworm-v1
```

`sbom: true` and `provenance: mode=max` are set on the push step only — the test build uses the
docker exporter via `load:`, which cannot carry attestations. `imagetools create` preserves them
into the final multi-arch index.

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
- **OpenSSF Scorecard** — branch protection, token permissions, pinned dependencies, dangerous
  workflow patterns. Produces the score behind the README badge. Runs on `main` only, since several
  checks inspect repository settings rather than the tree.

All three publish SARIF to the Security tab, so *Security → Code scanning* is the single place to
see everything: image vulnerabilities per architecture, repository secrets, workflow findings, and
the Scorecard result.

> **First run:** the Scorecard badge stays grey until the workflow has run once on `main` and
> published its results. Both badges track `main`, so they will not reflect a pull request.

## PR validation and linting

A PR runs the full per-image pipeline — build both architectures natively, smoke test, all five
scans, both gates — for **every image the `plan` job selects** (the changed ones, or all of them
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
by globbing `*/Dockerfile.ci`. The `version` field is per image, which is how `ci-java21` carries
`noble-v1` while everything else is `bookworm-v1`.

### Which images a run builds

A push or pull request builds **only the images whose directories changed** — a one-line fix to
`ci-ruby34` no longer rebuilds nine images and moves `latest` on all of them. Changing the
pipeline itself (either workflow file, or `images.json`) rebuilds everything, and the weekly
schedule and `workflow_dispatch` always rebuild everything — the rebuild is the security-update
mechanism and is never narrowed. Every ambiguous case (force-push, missing diff base) falls back
to the full list: over-building costs minutes, under-building leaves a stale published image
nobody notices. The chosen set is printed in the `plan` job's summary.

Each published index is also asserted to contain **both** platforms before the merge job goes
green — a one-architecture manifest is exactly the failure nobody notices until an Apple Silicon
machine pulls it.

### Future candidates

Java/JVM, .NET and PHP have now graduated from this list, alongside Rust and Ruby.

Nothing is queued behind them. The bar for the next one is unchanged: a concrete consumer. An
image with no consumer is scan noise and rebuild minutes — though the marginal cost of one is now
a directory, a JSON entry, and a Dependabot entry rather than 230 lines of copied workflow.

## Contributing and reporting problems

[CONTRIBUTING.md](CONTRIBUTING.md) covers the local loop and the pre-PR checks;
[SECURITY.md](SECURITY.md) covers how to report a vulnerability in a published image, and what is
in and out of scope.

## License

[MIT](LICENSE), and each image carries `org.opencontainers.image.licenses=MIT`.

That covers **this repository's** contents — the Dockerfiles, test scripts, workflow, and Makefile.
It says nothing about the software inside the published images: Debian and its packages, Node,
Python, Go, Rust, Ruby, Terraform, kubectl, the AWS CLI, and the Docker client each ship under
their own upstream licenses, which travel with the image. If you need to audit those, start from
the `mirror-*` package for the base and the pinned versions in
[ci-tools/Dockerfile.ci](ci-tools/Dockerfile.ci).
