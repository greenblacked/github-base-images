# base-images

Central repository for building and publishing shared container images to `ghcr.io`.

## Images

| Image | Base | Tag | Platforms |
|---|---|---|---|
| `ghcr.io/greenblacked/ci-node22` | `node:22-bookworm-slim` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-python313` | `python:3.13-slim-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
| `ghcr.io/greenblacked/ci-go125` | `golang:1.25-bookworm` | `bookworm-v1` | `linux/amd64`, `linux/arm64` |
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
- **`ci-tools`** — infra/deploy tooling as pinned upstream release binaries: Terraform, kubectl,
  the AWS CLI v2, and the Docker *client* (no daemon — it talks to the host's socket or a
  `docker:dind` service). Versions are pinned via `ARG`s in
  [ci-tools/Dockerfile.ci](ci-tools/Dockerfile.ci); a bump is a one-line PR that CI revalidates.

It deliberately does **not** contain `node_modules`, Next.js, Wrangler, application source,
Cloudflare credentials, repository secrets, or project-specific build tools. Those stay
controlled by each repository's `package-lock.json` and are installed with `npm ci`. Wrangler in
particular is a locked devDependency, so `npm run deploy:artifact` uses the repository's exact
version rather than one frozen into this image.

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

Each build prints the digest to pin, in its run summary under the Actions tab.

### Locally

The tag is multi-arch, so this runs natively on both Apple Silicon and x86 — no `--platform` flag
and no emulation:

```bash
docker run --rm -it -v "$PWD:/workspace" ghcr.io/greenblacked/ci-node22:bookworm-v1 bash
```

Useful for reproducing a CI failure with the exact toolchain the runner used. Both published
architectures are tested natively; to reproduce an amd64-specific failure from an Apple Silicon
machine, use `--platform linux/amd64`, which is emulated and slower.

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
> image (`ci-node22`, `ci-python313`, `ci-go125`, `ci-tools`) and every `mirror-*` package.
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
| `ghcr.io/greenblacked/mirror-debian:bookworm-slim` | `debian:bookworm-slim` (Docker Hub) |

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
  carrying Node and Debian security updates. It is bumped to `v2` only when the *contents* of the
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

Trivy runs three scans on every build, per architecture. All reports are printed to the log,
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

## PR validation and linting

Every PR runs the full pipeline — lint, build both architectures natively, smoke test, all three
scans, both gates — with every registry write skipped. Publishing (mirror push, digest push,
manifest tagging) happens only on `main`. A manually dispatched run from another branch follows
the same upstream-only, no-write validation path.

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

This is deliberately not a QEMU build. Emulating this image's 99-package apt layer would be
extremely slow, and multi-platform builds cannot `load:` into the Docker daemon — so the arm64
image could not be smoke-tested or scanned before publishing. arm64 runners are free for public
repositories, which makes the native path both faster and better tested.

Pinning a digest still works normally: pin the manifest-list digest from the run summary, and it
stays correct on both architectures.

## Adding another image

Each image is a `build-<name>` + `merge-<name>` job pair in
[the workflow](.github/workflows/build-and-push.yml), configured via a job-level `env:` block
(`IMAGE`, `VERSION`, `MIRROR`, `UPSTREAM`), with the matrix reserved for architectures — the
per-arch digest fan-out does not compose with a per-image matrix in one job.

To add an image: create `<image-name>/Dockerfile.ci` and `<image-name>/test.sh` following the
existing pattern, copy an existing `build`/`merge` job pair and change only its `env:` block and
job names, add the image's path to both `paths:` filters, mirror its base in the `mirror` job,
and add a `docker` ecosystem entry for its directory in
[.github/dependabot.yml](.github/dependabot.yml). Keep the build cache scoped per image and
architecture (`scope: <image>-<arch>`), or the builds evict each other's layers.

Known trade-off of this copy-the-pattern shape: `paths:` is one shared list, so a push touching
any single image's directory reruns every job pair, not just the changed one.

### Future candidates

Rust, Java/JVM, .NET, Ruby, and PHP images can be added with the exact same recipe once a
concrete consumer needs one. Until then they are deliberately not built — an image with no
consumer is just scan noise and rebuild minutes.
