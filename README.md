# base-images

[![Build and Push to GHCR](https://github.com/greenblacked/github-base-images/actions/workflows/build-and-push.yml/badge.svg?branch=main)](https://github.com/greenblacked/github-base-images/actions/workflows/build-and-push.yml)
[![Security](https://github.com/greenblacked/github-base-images/actions/workflows/security.yml/badge.svg?branch=main)](https://github.com/greenblacked/github-base-images/actions/workflows/security.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/greenblacked/github-base-images/badge)](https://scorecard.dev/viewer/?uri=github.com/greenblacked/github-base-images)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Shared container images for running CI in GitHub Actions container jobs, published to
`ghcr.io/greenblacked`. There are 21: language runtimes (Node.js, Python, Go, Rust, Ruby, Java,
PHP, .NET) and four tool images (infra, cloud, security scanners, database clients). Every image is
built for `linux/amd64` and `linux/arm64` on native runners, rebuilt daily to pick up distribution
security updates, blocked from publishing if a build adds a fixable HIGH/CRITICAL vulnerability or
bakes in a secret, and signed with keyless cosign plus a GitHub build provenance attestation. Tool
and base-image updates merge and publish themselves once every check is green, so the images stay
current with nobody tending them. The packages are public, so pulling needs no credentials.

The two workflow badges track **`main`**, not the latest run on any branch — so a red build badge
means the published images are stale or broken, not that someone's pull request is failing.

## Quick start

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
      - uses: actions/checkout@v5
      - run: npm ci
      - run: npm run check
```

No `credentials:` and no `packages: read` — the package is public, so the pull is anonymous
([why](docs/images.md#visibility-and-authentication)). `actions/setup-node` is not needed — Node is
already in the image. `runs-on` is only the host VM that provides the Docker daemon; your steps
execute inside the container, so the host's tooling is never used.

### Pin a digest in anything that matters

In protected deployment jobs, pin by digest instead of by tag:

```yaml
    container:
      image: ghcr.io/greenblacked/ci-node22@sha256:...
```

The tag is a rolling line: the daily rebuild moves it to a fresh digest, which is how fixes reach
you, but it also means the same tag is different bytes from one day to the next. A digest is
fixed, it can be [verified](#verifying-an-image) once and trusted after that, and because it is
the multi-arch manifest-list digest, one pin works on both architectures. Move the pin forward on
purpose to take the fixes.

Each build prints the digest to pin in its run summary, and every publish run uploads a
`digests.json` (`{image, version, digest}` per image) so pinning can be automated:

```bash
run=$(gh api 'repos/greenblacked/github-base-images/actions/workflows/build-and-push.yml/runs?branch=main&status=success&per_page=1' \
  --jq '.workflow_runs[0].id')
gh run download "$run" -R greenblacked/github-base-images -n digests
jq -r '.[] | select(.image == "ci-node22") | .digest' digests.json
```

Which images a given run's file covers is in
[Digests and `digests.json`](docs/pipeline.md#digests-and-digestsjson).

To reproduce a CI failure locally with the same toolchain, run the image directly; it is native on
both Apple Silicon and x86:

```bash
docker run --rm -it -v "$PWD:/workspace" ghcr.io/greenblacked/ci-node22:bookworm-v1 bash
```

## Image catalog

All images are `ghcr.io/greenblacked/<image>:<tag>`, for `linux/amd64` and `linux/arm64`. Every
one also ships a shared baseline: bash, git, CA certificates, curl, tar, gzip, unzip, xz, zstd, jq
and the OpenSSH client. Follow an image name for what it leaves out and why.

| Image | What's in it | Base | Tag |
|---|---|---|---|
| [`ci-node22`](docs/images.md#nodejs) | Node.js 22, npm, Playwright's Chromium libraries | `node:22-bookworm-slim` | `bookworm-v1` |
| [`ci-node24`](docs/images.md#nodejs) | Node.js 24, npm, Playwright's Chromium libraries | `node:24-bookworm-slim` | `bookworm-v1` |
| [`ci-python314`](docs/images.md#python) | Python 3.14, pip | `python:3.14-slim-trixie` | `trixie-v1` |
| [`ci-python313`](docs/images.md#python) | Python 3.13, pip | `python:3.13-slim-bookworm` | `bookworm-v1` |
| [`ci-python312`](docs/images.md#python) | Python 3.12, pip | `python:3.12-slim-bookworm` | `bookworm-v1` |
| [`ci-go`](docs/images.md#go-and-rust) | current stable Go, C toolchain | `golang:1-bookworm` | `bookworm-v1` |
| [`ci-rust`](docs/images.md#go-and-rust) | current stable Rust, rustfmt, clippy, C toolchain | `rust:1-bookworm` | `bookworm-v1` |
| [`ci-ruby40`](docs/images.md#ruby) | Ruby 4.0, RubyGems, Bundler | `ruby:4.0-slim-trixie` | `trixie-v1` |
| [`ci-ruby34`](docs/images.md#ruby) | Ruby 3.4, RubyGems, Bundler | `ruby:3.4-slim-bookworm` | `bookworm-v1` |
| [`ci-java25`](docs/images.md#java) | Temurin JDK 25 | `eclipse-temurin:25-jdk-noble` | `noble-v1` |
| [`ci-java21`](docs/images.md#java) | Temurin JDK 21 | `eclipse-temurin:21-jdk-noble` | `noble-v1` |
| [`ci-java17`](docs/images.md#java) | Temurin JDK 17 | `eclipse-temurin:17-jdk-noble` | `noble-v1` |
| [`ci-php85`](docs/images.md#php) | PHP 8.5 CLI, Composer | `php:8.5-cli-trixie` | `trixie-v1` |
| [`ci-php84`](docs/images.md#php) | PHP 8.4 CLI, Composer | `php:8.4-cli-bookworm` | `bookworm-v1` |
| [`ci-dotnet10`](docs/images.md#net-sdk) | .NET SDK 10.0 (LTS) | `mcr.microsoft.com/dotnet/sdk:10.0-noble` | `noble-v1` |
| [`ci-dotnet9`](docs/images.md#net-sdk) **(deprecated)** | .NET SDK 9.0 (STS) | `mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim` | `bookworm-v1` |
| [`ci-dotnet8`](docs/images.md#net-sdk) **(deprecated)** | .NET SDK 8.0 (LTS) | `mcr.microsoft.com/dotnet/sdk:8.0-bookworm-slim` | `bookworm-v1` |
| [`ci-tools`](docs/images.md#tool-images) | Terraform, kubectl, AWS CLI v2, Docker client | `debian:bookworm-slim` | `bookworm-v1` |
| [`ci-cloud`](docs/images.md#tool-images) | gcloud CLI, Azure CLI, kubectl | `debian:bookworm-slim` | `bookworm-v1` |
| [`ci-security`](docs/images.md#tool-images) | trivy, syft, grype, cosign, gitleaks | `debian:bookworm-slim` | `bookworm-v1` |
| [`ci-db`](docs/images.md#tool-images) | psql, mysql, redis-cli, golang-migrate | `debian:bookworm-slim` | `bookworm-v1` |

**Deprecated: `ci-dotnet8` and `ci-dotnet9`.** .NET 8 and .NET 9 reach end of support on
**2026-11-10**, and both images are retired after that date: they stop being rebuilt and
re-scanned. Move to `ci-dotnet10` (Ubuntu Noble, so check that any extra `apt-get` package names
still resolve). Details in
[docs/images.md](docs/images.md#deprecated-ci-dotnet8-and-ci-dotnet9).

A few things the table does not say:

- **These are CI images**, not `FROM` bases for application Dockerfiles, and there is no runtime
  image.
- **No project dependencies, source, credentials or project-specific build tools** are baked in;
  your lockfile and your workflow install those. Each image's `test.sh` asserts it.
- **No compiler toolchain in the slim runtime images** (Python, Ruby): add `build-essential` in
  your workflow if you build native extensions. **No browsers** in the Node images: install the one
  your lockfile asks for, as shown in
  [Running Playwright tests](docs/images.md#running-playwright-tests).
- **Three distribution lines.** Debian Bookworm (`bookworm-v1`), Debian Trixie for the newest
  Debian-based images (`trixie-v1`), and Ubuntu Noble where upstream publishes no Debian image
  (`noble-v1`). [Why](docs/images.md#patterns-worth-naming).
- **`ci-go` and `ci-rust` carry no version** because Go and Rust have no parallel supported lines;
  they track current stable. [Why](docs/images.md#go-and-rust).

[docs/images.md](docs/images.md) also covers the tool images in use, visibility, and building and
testing an image locally.

## What a green publish guarantees

Nothing is pushed until the image has been built, smoke-tested and scanned on both architectures.
Checks either **gate** (fail the build, nothing publishes; the two repository checks marked *merge*
block the pull request instead) or **report** (always visible, never block a publish). A gate is
reserved for problems this repository can fix; the rest is reported so you can see it.
[ADR 0003](docs/adr/0003-gates-vs-reports.md),
[ADR 0006](docs/adr/0006-gate-on-fixable-library-vulnerabilities.md) and
[ADR 0008](docs/adr/0008-self-updating.md) record why.

| Check | Kind | What it means for you |
|---|---|---|
| Smoke test (`test.sh`) | gate | Every promised tool is present, TLS verification works, nothing project-specific is baked in |
| Vulnerability gate | gate | The build adds no **fixable** HIGH/CRITICAL finding, in OS packages *or* libraries and binaries, that the image published before it did not already have |
| Secret gate | gate | No credential baked into the image, at any severity |
| Mirror integrity | gate | The base was copied by digest from upstream and verified before anything was built on it |
| Both platforms | gate | The published index contains `linux/amd64` and `linux/arm64` |
| Post-sign verification | gate | The cosign signature, SBOM and provenance attestations, and GitHub attestation all verify, under the identity below, in the run that published them |
| Dependency review | gate (merge) | On pull requests, no new dependency (mostly action versions) with a HIGH/CRITICAL advisory |
| Repository secret scan | gate (merge) | No credential committed to the repository's working tree |
| Full scan reports, SBOM | report | Every severity, unfixed findings, licenses, Dockerfile lint, a CycloneDX SBOM per architecture |
| Security tab (Trivy, OSV) | report | Unfixed HIGH/CRITICAL findings: the accepted risk, browsable over time |
| Workflow audits, history scan, Scorecard | report | zizmor, CodeQL, gitleaks over git history, OpenSSF Scorecard |
| Alerts report | report | One summary of every open alert, daily and after every publish; open fixable alerts are a warning, never a failure |
| Pin drift | report | A tracking issue when a pinned tool falls behind its vendor |

**Known upstream vulnerabilities ship until upstream fixes them.** A fixable finding the published
image already carries (pip's vendored urllib3, npm's bundled undici, a library inside the Azure
CLI, none of them fixed by any release yet) does not hold back a rebuild. Holding it back would
only withhold the other fixes that rebuild carries. Each one is listed in the gate's summary as
*known upstream* and in the alerts report, and goes away with the rebuild or update that picks up
the fixed release. Unfixed vulnerabilities never gate. A finding a build adds can only get past the
gate through an expiring, per-image, per-CVE entry in `.github/vuln-exceptions.json`, for a fix no
released artifact contains yet, lasting at most 90 days. The detail on every row is in
[docs/security.md](docs/security.md).

## Verifying an image

Every published index is signed with keyless cosign under the identity of the workflow that built
it. Check that identity; without it, `cosign verify` only proves that *somebody* signed the image:

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp \
    '^https://github\.com/greenblacked/github-base-images/\.github/workflows/build-image\.yml@refs/heads/main$' \
  ghcr.io/greenblacked/ci-tools:bookworm-v1
```

Or, independently, the GitHub build provenance attestation:

```bash
gh attestation verify oci://ghcr.io/greenblacked/ci-tools:bookworm-v1 \
  --repo greenblacked/github-base-images \
  --cert-identity https://github.com/greenblacked/github-base-images/.github/workflows/build-image.yml@refs/heads/main
```

The identity is `build-image.yml`, not `build-and-push.yml`, because signing happens in the
reusable workflow. Verify in the job that consumes the image: pin the digest, verify it, then run
it. [Verifying a signature](docs/security.md#verifying-a-signature) covers diagnosing a failed
verification, and [Attestations](docs/security.md#attestations) the SBOM and provenance attached
to every index.

## Tags and rebuilds

- **`bookworm-v1`, `trixie-v1`, `noble-v1`** are rolling lines; each image carries exactly one (see
  the catalog). The rebuild moves the tag to a fresh digest with distribution security updates
  and whatever the upstream base picked up. It goes to `v2` only when the image's *contents*
  change, a tool added or removed. `ci-go` and `ci-rust` also move to each new toolchain minor.
- **`latest`** exists for testing. Never use it in a protected deployment job.
- **`<commit-sha>`** identifies the exact build.
- **Rebuilds** happen daily, on every change to an image on `main`, after every automated update
  merges, and on demand. Only the current rolling tag is supported: older digests are never
  patched in place.
- **`digests.json`** in every publish run lists the digest for each image it built.
- **A retired or renamed image keeps its package**, pullable but no longer rebuilt or scanned, so
  move off it.

[docs/pipeline.md](docs/pipeline.md#tags-and-rebuilds) has the full contract, how the rebuild is
kept from reusing a stale cache, the mirrored bases, and which images each run builds.

## Documentation

- [docs/images.md](docs/images.md): per-image details, the tool images, Playwright, visibility,
  running and building locally.
- [docs/security.md](docs/security.md): the scans and gates, vulnerability exceptions, verifying
  signatures, attestations, repository checks, required checks, the alerts report.
- [docs/pipeline.md](docs/pipeline.md): mirrored bases, PR validation, which images a run builds,
  architectures, tags and rebuilds, `digests.json`, pin drift, automatic updates.
- [Architecture decision records](docs/adr/README.md): why it is built this way — why upstream
  bases are mirrored, why the vulnerability gate blocks only fixable findings (and why that now
  includes libraries, and only those a build adds), why builds are native rather than emulated,
  why every action is SHA-pinned, and how the repository updates itself.

## Contributing and reporting problems

[CONTRIBUTING.md](CONTRIBUTING.md) covers the local loop, the pre-PR checks, and
[adding another image](CONTRIBUTING.md#adding-another-image). [SECURITY.md](SECURITY.md) covers how
to report a vulnerability in a published image privately, and what is in and out of scope.

## License

[MIT](LICENSE), and each image carries `org.opencontainers.image.licenses=MIT`.

That covers **this repository's** contents — the Dockerfiles, test scripts, workflow, and Makefile.
It says nothing about the software inside the published images: Debian and its packages, Node,
Python, Go, Rust, Ruby, PHP, .NET, Java, Terraform, kubectl, the AWS CLI, the Docker client, the
gcloud and Azure CLIs, the database clients, and the scanning tools in `ci-security` each ship
under their own upstream licenses, which travel with the image. If you need to audit those, start
from the `mirror-*` package for the base, the pinned versions in the relevant `Dockerfile.ci`, and
the CycloneDX SBOM published as a build artifact for every image and architecture.
