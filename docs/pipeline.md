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
- [Automatic updates](#automatic-updates)
- [Image lifecycle](#image-lifecycle)

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

Each [images.json](../.github/images.json) entry names both: `upstream` is the base on Docker Hub
or MCR, and `mirror` is its copy under `ghcr.io/greenblacked`, one `mirror-*` package per upstream
repository with the upstream tag unchanged. For example:

| Mirror | Upstream |
|---|---|
| `ghcr.io/greenblacked/mirror-node:22-bookworm-slim` | `node:22-bookworm-slim` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-debian:bookworm-slim` | `debian:bookworm-slim` (Docker Hub) |
| `ghcr.io/greenblacked/mirror-dotnet:10.0-noble` | `mcr.microsoft.com/dotnet/sdk:10.0-noble` (MCR) |

`scripts/image-lifecycle.sh check` (run by `scripts/lint.sh`) fails if a mirror does not carry its
upstream's tag, or a `Dockerfile.ci`'s `ARG BASE_IMAGE` default is not the entry's `upstream`.

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
the daily rebuild pick up upstream patches — freezing those to a digest would break the update
mechanism this repo depends on.

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
Publishing (mirror push, digest push, manifest tagging) happens only on `main`. A run dispatched
on another branch builds the images that branch changes, from upstream bases, with no registry
writes.

A `lint` job runs first and cheaply, so a typo never spends runner minutes on multi-arch builds:
**hadolint** on every `*/Dockerfile.ci` (DL3008 is ignored inline — apt pins would go stale and
break the daily rebuild, which is the actual update mechanism; DL3006 is ignored inline on the
`FROM ${BASE_IMAGE}` lines — the ARG default is tagged, hadolint just can't resolve it),
**actionlint** on the workflows, and **shellcheck** on every `*/test.sh` (SC2016 is ignored per
file — check strings are deliberately single-quoted so they expand inside the container, not on
the host). `make lint` runs the same battery locally; see
[Building and testing an image locally](images.md#building-and-testing-an-image-locally).

**Dependabot** ([.github/dependabot.yml](../.github/dependabot.yml)) keeps the workflow's action
pins current with daily PRs. It also watches each image's `ARG BASE_IMAGE`, but on these tags it
can only propose a different runtime line, which it is told to ignore, so base images move with
the daily rebuild instead ([Automatic updates](#automatic-updates)). Because PR validation runs
the full build/test/scan stack, a Dependabot bump arrives pre-verified, and it then merges itself.

Which four checks a pull request is merged on, and why `CI result` stands in for every per-image
job, is in [Required checks](security.md#required-checks).

## Which images a run builds

A push or pull request builds **only the images whose directories changed** (a pull request that
changes none, and no pipeline file, builds nothing) — a one-line fix to `ci-ruby34` does not
rebuild every other image or move `latest` on them. Changing the pipeline itself (either
workflow file, `images.json`, or the four scripts `build-image.yml` runs) rebuilds everything; a
change to `.github/vuln-exceptions.json` rebuilds the images whose entries changed. A
`workflow_dispatch` on a branch other than `main` is planned the same way as a pull request,
against where the branch left `main`. That is how the automated update PRs get their checks
([Automatic updates](#automatic-updates)), so a kubectl bump builds `ci-tools` and `ci-cloud` and
nothing else. An [image lifecycle](#image-lifecycle) pull request that adds or retires an image
changes `images.json`, so it builds everything; one that only announces a deprecation changes no
image and builds nothing. The daily schedule and a `workflow_dispatch` on `main` always rebuild everything —
the rebuild is the security-update mechanism and is never narrowed. Every ambiguous case (force-push, missing diff base) falls back
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

- **`<codename>-v1`** — `bookworm-v1`, `trixie-v1`, `noble-v1`, and `resolute-v1` once an image
  is built on Ubuntu 26.04 — is a rolling contract line; each image carries exactly one, per the
  [image catalog](../README.md#image-catalog). The daily
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
  the daily rebuild and the Trivy re-scan while staying published and pullable. It then quietly
  accumulates unpatched CVEs, and a consumer still pointing at it sees a working pull and no
  signal at all. **Deleting the old package is therefore part of a rename, not an optional
  tidy-up.** `ci-rust185` and `ci-go125` were retired this way and should be deleted from the
  package settings. The same applies to images retired at end of support, such as
  [`ci-dotnet8` and `ci-dotnet9`](images.md#deprecated-ci-dotnet8-and-ci-dotnet9), and to every
  image the [image lifecycle](#image-lifecycle) retires: its pull request says so.
- **`<commit-sha>`** identifies the exact build.

Every image rebuilds on every push to `main` touching any image directory, daily on a schedule,
and on demand via *Run workflow*. A merge made by automation triggers no push build, so the merge
bot dispatches a full rebuild on `main` after merging
([Automatic updates](#automatic-updates)).

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

> **Watch out:** GitHub disables scheduled workflows after 60 days with no repository activity.
> The automated updates normally count as activity, but if they stop, the daily rebuild then stops
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

A change-detection run's `digests.json` covers only the images that run rebuilt; a scheduled run,
or one dispatched on `main`, always covers all of them. A run in which some image failed still
aggregates the ones that published and verified — its summary says how many of the planned images
that is — but the run is red, so the `status=success` query above will not pick it.

The digest is the manifest-list digest, so one pin covers both architectures. Having pinned it,
verify it before running it: see [Verifying a signature](security.md#verifying-a-signature).

## Pin drift

Most of this repository's supply chain is watched by something: Dependabot tracks the action
pins, the daily rebuild re-resolves each Dockerfile's floating `ARG BASE_IMAGE` tag, and the
rebuild plus the Trivy gate cover the OS packages and the libraries the images carry. Its config carries a seven-day `cooldown` on every
ecosystem — nothing is adopted the day it ships, since the window between publication and
discovery is exactly when a same-day bump would pull in a compromised release — and one `groups`
rule for `github/codeql-action`, whose `init`, `analyze` and `upload-sarif` subpaths are one action
on one SHA. Without the grouping Dependabot opens a PR per subpath, and since CodeQL rejects `init`
and `analyze` on different versions, two of the three fail by construction while the third passes
as a third of a change.

The tools installed as pinned release binaries — Terraform, kubectl, the AWS CLI, the Docker
client, gcloud, Composer, Playwright, npm, the json gem in `ci-ruby40`, the five scanners in
`ci-security` (and the second gitleaks in `security.yml`), the osv-scanner binary the pipeline
itself runs, and the hadolint and actionlint engines in `scripts/lint.sh` — were the gap: nothing
read them, so they moved only when a human remembered. An audit found six behind at once.

[pin-drift.yml](../.github/workflows/pin-drift.yml) closes that gap. Daily, it compares every
pinned version against the version its vendor currently ships and maintains **one** tracking issue
— opened when something falls behind, updated while it stays behind, closed automatically once
every pin is current.

It reports rather than gates. Drift is not a broken build; it is a bump to make through the
normal PR path, with a fresh checksum. Failing builds over it would just teach people to ignore a
permanently red repository. Since [automatic updates](#automatic-updates), the bump is made for
you, and the issue is mainly a record of what is still open.

The issue is only as fresh as its last daily run, so re-dispatch the workflow before working
from the table by hand — more than once a bump has been prepared against a version already
superseded. The lint engines are in it too: `HADOLINT_VERSION` and `ACTIONLINT_VERSION` in
`scripts/lint.sh`, each with its per-platform checksums as named variables beside it. They used to
be worse. CI ran `hadolint-action`, which bundles its own hadolint binary, so its version was
coupled to `HADOLINT_VERSION` with nothing enforcing it, and twice a Dependabot PR moving only the
action was green while putting local and CI on different linters. The `lint` job now runs
`scripts/lint.sh` itself, so there is one pinned version of each engine, in one file; the comments
above the pins and above the `lint` job in `build-and-push.yml` record that history.

```bash
./scripts/check-pins.sh              # the same check, locally
```

How to bump a pin, including its checksums, is in
[CONTRIBUTING.md](../CONTRIBUTING.md#what-does-not-belong-in-an-image).

## Automatic updates

Each image stays current without anyone watching it ([ADR 0007](adr/0007-automatic-updates.md),
[ADR 0008](adr/0008-self-updating.md)). Every update arrives as a pull request that runs the full
pipeline and the four [required checks](security.md#required-checks). It merges itself once all
four are green, and is published the same hour. Nothing merges red.

**Where the updates come from.** Base images come from the daily rebuild, not from Dependabot.
Each `ARG BASE_IMAGE` is a floating tag (`python:3.13-slim-bookworm`, `golang:1-bookworm`), and
the rebuild re-resolves it through the [mirror](#mirrored-upstream-base) every day, so upstream's
patch releases arrive that way. On tags of that shape the only versions Dependabot could propose
are a different runtime line (Python 3.14, Node 25, Go 2), which its docker entries ignore, so in
practice they propose nothing. They stay as a safety net: no update may change what an image is,
and a new line is a new image. Dependabot, daily, keeps the action pins current. And
[pin-bump.yml](../.github/workflows/pin-bump.yml), daily after pin drift, for the hand-pinned tools.
For each tool that is behind, it opens (or refreshes) one PR on a `pin-bump/<tool>` branch, with
the version and its checksums rewritten by `scripts/bump-pins.sh`. Pins kept in more than one
place move together: kubectl in `ci-tools` and `ci-cloud`, Composer in every PHP image, gitleaks
in `ci-security` and `security.yml`, npm and Playwright in every Node image. Which images carry a
pin is read from the Dockerfiles of the images in `images.json`, so an image the lifecycle adds or
retires needs no change to the pin tooling. Every checksum is
read from the vendor's own checksums file or registry record for that version. None is computed
from a download. Both wait the same seven-day cooldown after a release.

| Pin-bump class | When | Outcome |
|---|---|---|
| `auto` | vendor checksum or registry integrity, not a major version, released 7+ days ago | merges itself once green |
| `review` | no vendor checksum (AWS CLI, Docker client, gcloud), a major version, or an unknown release date | labelled `needs-review` as information; merges itself once green |
| deferred | released less than 7 days ago | no PR until it is 7 days old |

A push made with the workflow token starts no workflow, so pin-bump dispatches *Build and Push to
GHCR* and *Security* on the branch. Their check runs land on the PR's head commit. The dispatched
build is planned like a pull request and builds only the images the bump touches
([Which images a run builds](#which-images-a-run-builds)). For the same reason, `Dependency review`
also runs on a dispatch from any branch but `main`, comparing it with `main`
([Repository security checks](security.md#repository-security-checks)).

**Merging.** [merge-bot-prs.yml](../.github/workflows/merge-bot-prs.yml) is started by:

- **the bot branch's own CI.** Build and Push and Security end with a `request-merge` job that
  dispatches the merge bot when they ran on a `pin-bump/*`, `lifecycle/*` or `dependabot/*`
  branch by dispatch. GitHub starts no `workflow_run` for a run that a `GITHUB_TOKEN` dispatch
  started, which is how every bot branch's CI is started, so the `workflow_run` trigger never
  sees these. A dispatch made with `GITHUB_TOKEN` does start a run. Whichever of the two finishes
  second finds all four checks complete;
- **daily backstops:** the scheduled rebuild on `main`, pin bump and image lifecycle each dispatch
  it at their end;
- **`workflow_run`**, when Build and Push or Security finishes on a pull request or on `main`
  (not for a run Dependabot started, whose token is read-only);
- **the hourly schedule**, a backstop only: GitHub delays and drops scheduled runs under load;
- **a person**, from *Actions*.

Dependabot PRs rely on the hourly schedule and the daily backstops: their own CI runs with a
read-only token and cannot dispatch anything. For every open `dependabot/*` PR by
Dependabot, and every `pin-bump/*` and `lifecycle/*` PR by `github-actions[bot]`, it merges
(squash, leased to the head commit it checked) when:

- every commit on the branch is the bot's own, by author and committer;
- the latest run of `CI result`, `Repository secret scan`, `CodeQL (workflows)` and
  `Dependency review` on the head commit each completed with success;
- the branch merges cleanly. GitHub answers that as yes, no, or not computed yet (`mergeable:
  null`), and every merge moves `main`, which sends every other open PR back to "not computed
  yet". So a green PR whose answer is not computed yet is read again after 2, 4, 8 and 16
  seconds, about 30 seconds in all, so that one run merges every green PR rather than one an
  hour. Still not computed after that, it waits for the next run; it is never taken as a yes;
- the PR is not labelled `hold`, read from the PR itself, and again together with the head commit
  right before the merge.

After merging it dispatches *Build and Push to GHCR* and *Security* on `main`, which rebuilds and
publishes every image. It needs no ruleset, no *Allow auto-merge* setting, no PAT and no app. Its
run summary has one row per PR: merged, waiting (and on what), red, stale, or left alone (and
why). A red, stale or unreadable PR is a warning there; a merge or dispatch that failed turns the
run red.

One limit is expected but unverified until the first action bump: the workflow token can never
hold the `workflows` permission, and GitHub may refuse to merge a PR that changes
`.github/workflows/*` without it. That covers Dependabot's action bumps and the gitleaks and
osv-scanner pin bumps. GitHub's documented Dependabot recipe merges action bumps with this token,
so it is expected to work. If GitHub refuses, the PR is reported as skipped with a warning, and the
run stays green. Merge it by hand, or give the workflow a token with `workflows: write`.

A red Dependabot PR that merges cleanly, whose branch is behind `main`, and that changes nothing
under `.github/` gets a fresh try against `main`. The bot records the attempt in a PR comment,
merges `main` into the branch with GitHub's *update branch*, and dispatches CI on it. A
dispatched run executes the branch's own workflow files with write tokens, so a PR that touches
`.github/` (every action bump) is never refreshed or dispatched on. It would run the proposed
action version with more access than Dependabot's read-only `pull_request` run. Such a PR, when
red, is reported *stale*: Dependabot rebases it on a conflict or supersedes it with its next
version, and it merges whenever its own CI is green. This happens at most once per `main` commit and twice in
all; after that the PR is *stale*. From the first refresh on, Dependabot treats the PR as edited
and no longer rebases it, so a stale or conflicting refreshed PR waits for Dependabot's next
version of the update, which opens a new PR that supersedes it, or for a person. Pin-bump and
lifecycle branches are not updated this way: their daily run rebuilds a branch that fell behind
`main` from scratch.

**Stopping it.** Label a PR `hold` and it is never merged. To stop all merging, disable the
*Merge bot* workflow under *Actions*. Every PR still runs its checks.

**Runs are idempotent.** A pin-bump PR at an older version is rebuilt from `main` and updated in
place. One already at the target version is not rebuilt, but if its required checks never
reported on its head commit, the workflows whose checks are missing are dispatched again. A check
that ran red stays red; it is not re-dispatched. A PR closed unmerged is not reopened for the same
version. The pin-bump run summary has one row per tool: old and new version, class, PR, and what
was done; a failed dispatch or an unreadable check-run list is an error there, and the run goes
red.

A pin-bump branch with a commit by anyone else, as author or as committer, is not touched at all:
not rebuilt, not re-dispatched, and not merged. That includes the merge commit GitHub's *Update
branch* button makes, so don't use it on these PRs. If it was used, either merge the PR by hand
once it is green, or give the branch back by dropping the merge commit, after which the next run
rebuilds it:

```bash
git fetch origin
git push --force-with-lease origin origin/pin-bump/<tool>^1:refs/heads/pin-bump/<tool>
```

Deleting the branch instead closes the PR, and a closed PR is not reopened for that version; the
next version gets a new one.

The jobs that push and merge run from `main` only. Dispatching pin-bump from any other branch runs
a read-only `preview` job instead, which prints what the branch's scripts would do; the merge bot
has a `dry_run` input for the same purpose.

**Settings the repository needs.** *Settings → Actions → General → Workflow permissions*: **Allow
GitHub Actions to create and approve pull requests** (without it, no pin-bump PR can be opened),
and *Settings → General → Pull Requests*: **Allow squash merging**. Nothing else, unless GitHub
turns out to refuse workflow-file merges with the workflow token (above).

```bash
./scripts/bump-pins.sh --unit kubectl          # bump one tool in your working tree
./scripts/check-pins.sh --format json > drift.json
./scripts/bump-pins.sh --drift drift.json      # bump everything that is behind
./scripts/test-bump-pins.sh                    # offline tests of both scripts; scripts/lint.sh runs them
./scripts/test-merge-bot-prs.sh                # offline tests of the merge bot
GITHUB_REPOSITORY=greenblacked/github-base-images DRY_RUN=1 ./scripts/merge-bot-prs.sh   # what it would merge now
```

## Image lifecycle

[image-lifecycle.yml](../.github/workflows/image-lifecycle.yml) runs daily at 09:07 UTC, after
pin bump, and keeps the set of images in step with upstream's support lines
([ADR 0009](adr/0009-image-lifecycle.md); the rules are in
[Image lifecycle](images.md#image-lifecycle)). The work is in `scripts/image-lifecycle.sh`:

- **Reads** each runtime's releases from the [endoflife.date](https://endoflife.date) API (v1),
  and which tags exist from Docker Hub's tag API or MCR's tag list. Debian's and Ubuntu's releases
  come from endoflife.date too, to choose the distribution of a new image. Anything it cannot read
  means no action on what depended on it, and a warning in the run summary: never an add or a
  retirement on a guess. "Not yet" (an RC tag only, an LTS date not reached) is not a warning;
  a line that is GA but has no tag on either distribution yet is a `::notice::` and a "Waiting"
  entry in the summary, every day until the tag appears.
- **Opens one pull request per action**, on `lifecycle/add-<image>`, `lifecycle/deprecate-<image>`
  or `lifecycle/retire-<image>`, the same way pin bump does: rebuilt from `main`, one commit by
  `github-actions[bot]`, pushed leased to the SHA it saw, CI dispatched on the branch, healed on
  the next run if a dispatch was lost, never pushed over a commit someone else made, and never
  reopened once a person closed it unmerged. The merge bot merges it when green, as above.
- **Closes what is no longer due.** An open lifecycle PR whose change is not in today's plan (a
  retirement whose end of support moved into the future upstream, an add whose line was
  withdrawn) is closed with a comment saying why, labelled `lifecycle-superseded`, and its branch
  deleted. Only when that runtime's plan was complete: if endoflife.date or a registry could not be
  read, or anything else raised a warning for it, nothing is closed. A PR someone else committed
  to is left open with a warning. A PR closed this way is not a veto, so a fresh one opens if the
  change becomes due again; one a person closed is a veto. And because the merge bot could merge a
  retirement in the hours before the next daily run closes it, it merges a `lifecycle/retire-*`
  PR only while the end-of-support date in the PR's marker has passed and `main`'s
  `.github/lifecycle.json` still records the image deprecated with that date; a missing marker or
  an unreadable record is never merged.
- **Adds** copy the family's newest image directory (skipping one that carries a line-specific
  workaround, such as `ci-ruby40`'s json gem replacement), with the version, base, description,
  distribution and version assertions moved, and add the `images.json` entry, the Dependabot
  entry, the catalog row and the docs bullet. The sibling's unexpired package-scoped
  [vulnerability exceptions](security.md#vulnerability-exceptions) are copied with the same
  expiry, since a new image is gated against an empty baseline.
- **Deprecations** record the image in [.github/lifecycle.json](../.github/lifecycle.json), from
  which the catalog marker, the README and SECURITY.md notices and the docs section are generated.
  `.github/lifecycle.json` is not a pipeline file, so such a pull request builds nothing.
- **Retirements** remove the directory, the `images.json`, Dependabot and vulnerability-exception
  entries and the catalog row, point usage examples that pull the image at its successor, and
  keep a *Retired* note under the anchor the deprecation notice had.
- **Never changes `.github/workflows/`**: the workflow token cannot push workflow files, and the
  script refuses a commit that touches one. `images.json` and `dependabot.yml` are ordinary files
  for `contents: write`.

`scripts/image-lifecycle.sh check`, run by `scripts/lint.sh`, keeps the hand-maintained and
generated parts honest: the Dependabot docker directories, the README catalog rows (with their
base and tag) and the `docs/images.md` bullets are each exactly the `images.json` images, every
`ARG BASE_IMAGE` default is its entry's `upstream`, the README count is right, and the generated
deprecation markers and notices are what `.github/lifecycle.json` says.

A dispatch from any branch other than `main` runs a read-only `preview` job instead, which prints
what that branch's script would do.

```bash
./scripts/image-lifecycle.sh plan                  # what is due today, as JSON lines
./scripts/image-lifecycle.sh apply add --image ci-python315 --upstream python:3.15-slim-trixie
./scripts/image-lifecycle.sh check                 # the consistency checks lint runs
./scripts/test-image-lifecycle.sh                  # offline tests; scripts/lint.sh runs them
GITHUB_REPOSITORY=greenblacked/github-base-images DRY_RUN=1 ./scripts/image-lifecycle.sh prs
```
