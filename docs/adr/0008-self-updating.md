# 0008 — Self-updating: a regression gate, a daily cadence, and merge-when-green

**Status:** accepted; supersedes the absolute vulnerability gate and the failing alerts report of
[0006](0006-gate-on-fixable-library-vulnerabilities.md), and the auto-merge, review and
publishing parts of [0007](0007-automatic-updates.md); how the merge bot is started is corrected by
[0009](0009-image-lifecycle.md#merge-bot-trigger); the gate gains the base image as a second
baseline in the [2026-10-14 amendment](#amendment-2026-10-14-the-base-image-is-a-second-baseline);
`review` pin bumps wait a first-seen cooldown before they merge, and the cooldown fails closed, in
the [2026-10-17 amendment](#amendment-2026-10-17-the-cooldown-fails-closed-and-has-a-clock-of-its-own)

**Date:** 2026-10-06

## Context

The owner uses these images in other repositories and wants to spend no time on them: the
repository should keep itself current, for security fixes and for new versions, with nobody
watching it.

It did not. Since 2026-10-05 the vulnerability gate failed on five images, on both architectures,
over findings no release could fix: urllib3 2.7.0 vendored in pip (`ci-python313`,
`ci-python314`), brace-expansion and undici bundled in every current npm (`ci-node22`,
`ci-node24`), and PyJWT and urllib3 inside the Azure CLI (`ci-cloud`). The advisories name fixed
versions, so `ignore-unfixed` did not apply, but no upstream artifact contains them. The effects:

- the scheduled rebuild published nothing for those images, so they also stopped receiving the
  Debian security updates the rebuild exists to deliver;
- every pull request that rebuilt them was red, automated updates included;
- the alerts report failed every run on the same findings, so `main` was red with nothing to do.

Exceptions ([0006](0006-gate-on-fixable-library-vulnerabilities.md)) could cover each finding, but
only by hand, one CVE at a time, renewed every 90 days. That is the time the owner does not want
to spend.

The update path had gaps too. Dependabot and the pin bumps ran weekly. Only minor and patch
updates with a vendor checksum merged themselves, everything else waited for a person. Merging
relied on GitHub auto-merge, which only waits for the checks the `main` ruleset requires. The
ruleset is not active and the setting is probably off, so nothing merged. A merged update then
waited up to a week for the next rebuild to publish it.

## Decision

### 1. The vulnerability gate blocks only what a build introduces

For each image and architecture, `build-image.yml` scans the candidate image and the image
currently published for the same tag (its per-arch manifest digest), with the same Trivy binary,
the same on-disk database, the same flags (HIGH/CRITICAL, `ignore-unfixed`, `os,library`) and the
same exceptions. [scripts/vuln-gate.sh](../../scripts/vuln-gate.sh) compares the two reports by
(vulnerability id, package name, package type), where the type is Trivy's result type (`debian`,
`node-pkg`, `python-pkg`, `gobinary`, …):

- **new** (candidate only): blocks the publish;
- **known upstream** (both): listed, does not block;
- **fixed by this build** (published only): listed.

It fails closed. A new image or a new tag has no published image, so the comparison runs against
an empty baseline and every finding blocks, the same as the old gate. The same strict comparison
runs when the published image cannot be resolved or scanned for any reason, and the summary says
which reason it was. Registry reads are retried three times (5s, 15s, 45s) before that, so one
hiccup does not make the gate strict. The reads are authenticated with the job's own token in
every context, pull requests included, through a throwaway Docker config deleted straight after,
so private packages have a baseline too. An unreadable report is a failure, never "no findings". The summary is a
small table, never the full Trivy output, which had exceeded the 1 MiB step-summary limit.

The alerts report still lists every open fixable alert, but open fixable alerts are now a warning,
not a failure. It still fails when it could not read the alerts.

### 2. Everything runs daily

Dependabot (every ecosystem), pin drift, pin bump, the image rebuild, the repository security
scans and the alerts report run daily. The seven-day cooldown is unchanged everywhere: a version
is still adopted no sooner than seven days after release, just on the day it qualifies instead of
up to a week later.

Base images do not reach the images through Dependabot. Each `ARG BASE_IMAGE` is a floating tag
(`python:3.13-slim-bookworm`, `node:22-bookworm-slim`, `golang:1-bookworm`), and the daily rebuild
re-resolves it through the mirror, so upstream's patch releases arrive that way. On tags of that
shape the only versions Dependabot can propose are a different runtime line (Python 3.14, Node 24,
Go 2), so in practice its docker entries propose nothing. They ignore semver-major and
semver-minor updates anyway, as a safety net: no update may change what an image is. Dependabot's
real work here is the action pins.

A dispatched build on any branch other than `main` is planned like a pull request: it builds only
the images the branch changes, compared with `main`. A dispatch on `main` stays a full rebuild.

### 3. Green pull requests merge themselves, through our own workflow

[merge-bot-prs.yml](../../.github/workflows/merge-bot-prs.yml) runs when Build and Push or Security
finishes, hourly, and on demand. (Corrected in [0009](0009-image-lifecycle.md#merge-bot-trigger):
"when Build and Push or Security finishes" did not hold for bot PRs. GitHub starts no
`workflow_run` for a run that a `GITHUB_TOKEN` dispatch started, so those two workflows now
dispatch the merge bot themselves when they finish on a bot branch, and three daily jobs dispatch
it as a backstop.) It merges every open `dependabot/*` PR by Dependabot and every
`pin-bump/*` PR by `github-actions[bot]` when all of these hold:

- every commit is the bot's own, by author and committer;
- `CI result`, `Repository secret scan`, `CodeQL (workflows)` and `Dependency review` each have
  their latest GitHub Actions run on the PR's head SHA completed with success;
- the PR merges cleanly;
- it has no `hold` label.

The merge is `gh pr merge --squash --match-head-commit <sha>`. This includes majors and the bumps
labelled `needs-review` (AWS CLI, Docker client, gcloud, and any major) — those once their
first-seen cooldown is over ([2026-10-17 amendment](#amendment-2026-10-17-the-cooldown-fails-closed-and-has-a-clock-of-its-own)).
The full build, smoke tests and gate are the safety net, and the label is information only. After a merge it dispatches
Build and Push and Security on `main`, which publishes the update the same hour.

`hold` and the head SHA are read from the PR itself, and read again right before the merge.

A red Dependabot PR that merges cleanly, is behind `main` and changes nothing under `.github/` is
brought up to date: at most once per `main` commit and twice in all. The bot posts a marker
comment, calls `update-branch` leased to the head it read, and dispatches CI on the branch. A PR
that changes anything under `.github/` (every action bump) is never refreshed and never
dispatched on. A dispatched run executes the branch's own workflow files with write tokens
(`packages`, `id-token`, `attestations`, `security-events`). For an action bump that would run
the proposed, not-yet-merged action version with more access than Dependabot's own read-only
`pull_request` run gives it, which defeats the point of the cooldown. Such a PR is marked stale
when it is red; it still merges when its `pull_request` CI is green. The only merge commit the authorship check
accepts is one whose parents match a marker written by `github-actions[bot]`. After a refresh,
Dependabot treats the PR as edited and stops rebasing it. If it stays red after two refreshes it
is marked stale and waits for Dependabot's next version of the update, which opens a new PR that
supersedes it. Pin-bump branches are never updated this way, because `pin-bump-prs.sh` rebuilds
them from `main` itself.

The workflow uses `GITHUB_TOKEN` only, with `contents`, `pull-requests` and `actions` write and
`checks` read. It needs no PAT, no app, no ruleset and no auto-merge setting. One limit is
expected but not yet seen either way: `GITHUB_TOKEN` can never hold the `workflows` permission,
and GitHub may refuse to merge a PR that changes `.github/workflows/*` without it (Dependabot's
action bumps, and the gitleaks and osv-scanner pin bumps). GitHub's documented Dependabot recipe
merges action bumps with this token, so it is expected to work. The first action bump will show
whether it does. If GitHub refuses, the bot marks that PR skipped with a warning (merge it by
hand, or give the workflow a token with `workflows: write`), and the run stays green.

## Why

- **The gate's job is to stop this repository from making things worse.** A finding the published
  image already carries is not made worse by publishing a rebuild that still carries it. Blocking
  that rebuild only withholds the fixes it does carry. A finding a build *adds* is the one decision
  this repository actually makes, and that one still blocks.
- **Identity is (id, package, type), not version or path.** The same CVE in the same package at a
  new patch version is upstream moving without fixing it, not a regression. The type keeps a CVE
  known in a Debian package from hiding the same id newly reported against an npm, PyPI or Go
  package of the same name. The cost is that one more copy of an already-known vulnerable package,
  of the same type, in a new path does not block. That is accepted.
- **Strict on any failure.** Telling "not published yet" from "registry error" is done only for
  the message. Both run strict, and strict can only fail a build that a successful comparison
  would have passed. It can never pass one that the comparison would have failed.
- **Daily** because fixes should reach consumers the day they are installable, and because the
  build cache is already scoped per day. The cooldown, not the cadence, is the supply-chain
  control.
- **Our own merge step** because GitHub auto-merge is only as strict as the ruleset, which is
  inactive, and it needs a setting no workflow can turn on. Reading the checks on the exact SHA
  and merging with `--match-head-commit` gives the same guarantee without depending on either.
- **Majors merge too** because a person was the only thing between a green major and `main`. The
  owner chose zero touch, and a major that builds, passes every smoke test and adds no
  vulnerability is what the pipeline was built to accept.
- **Refreshing red Dependabot PRs** because Dependabot rebases only on a conflict. A PR that went
  red under an old `main` (for example the strict gate this record replaces) would otherwise stay
  red forever. `main` moves with every merge, and a refresh can be a full build of every image, so
  it is bounded twice: once per `main` commit, recorded before the attempt, and two in all. Two
  tries against two different `main`s is enough to tell `main`'s fault from the update's.

## Consequences

- **Known upstream vulnerabilities ship until upstream fixes them.** They are listed in every
  gate summary as *known upstream* and in the alerts report, and close on their own when the daily
  rebuild or an automated bump picks up the fixed release. A green publish now means *no fixable
  HIGH/CRITICAL vulnerability that the previous published image did not already have*. It no
  longer means *none at all*.
- Exceptions ([0006](0006-gate-on-fixable-library-vulnerabilities.md)) remain, applied to both
  scans, but they are needed only for a finding a build *adds* that no release fixes. An expired
  exception for a known finding breaks nothing.
- Every automated update merges without a person. The `hold` label stops one PR, and disabling
  *Merge bot* stops all of them. A PR the token is not allowed to merge (workflow files) is left
  with a warning for a person.
- A refreshed Dependabot PR is no longer Dependabot's to rebase. If it conflicts later, it waits
  for Dependabot's next version, which supersedes it.
- PRs are merged one after another on CI results from their own base. Two updates that each pass
  alone but fail together would turn the post-merge publish on `main` red. Nothing broken
  publishes, and the next update or a person fixes `main`.
- Dispatching CI on a refreshed Dependabot branch runs that branch's workflows with the dispatch
  token. That is why it is done only for branches that change nothing under `.github/`, so the
  workflows that run are `main`'s. The authorship check limits the rest of the branch to
  Dependabot's verified commits and this workflow's own merge commit. Pin-bump branches are
  dispatched on too, but their content is made by this repository's own script from vendor
  checksums, not proposed by a third party.
- A red action bump is never re-run here. If its red was `main`'s fault, it waits for Dependabot to
  rebase it (on a conflict) or for the next version, which supersedes it.
- More runner time: a full rebuild every day. A dispatched bump PR now builds only the images it
  touches, which offsets part of it.

## Revisit if

- An inherited finding stays open for months with a fixed release available. That means the
  rebuild or bump path is not picking it up, and the cause is a pipeline bug, not a reason to
  return to the absolute gate.
- A merged update breaks a consumer in a way CI could have caught. Then add that check to
  `test.sh` or the gate before narrowing what merges.
- GitHub lets `GITHUB_TOKEN` merges trigger push workflows, which would make the publish dispatch
  unnecessary, or the ruleset becomes active, which would make GitHub auto-merge an equivalent
  option.
- The daily cadence costs more runner time than this repository can use.

## Amendment (2026-10-14): the base image is a second baseline

**Context.** Comparing with the published image alone still blocked on findings a *newer base*
brings. Two failures showed it:

- `ci-dotnet8`: the .NET SDK 8.0.426 image ships its own copies of `Microsoft.Build.Tasks.Core`
  and `System.Security.Cryptography.Xml` under `usr/share/dotnet/sdk/8.0.426/`, with fixable
  advisories against them. The published `ci-dotnet8`, built on the previous SDK, did not have
  them, so the gate called them new and blocked — including the daily rebuild on `main`, which
  carried twelve runtime fixes, two of them CRITICAL.
- `ci-python315`, a new image: with nothing published, the gate ran strict and blocked on findings
  that come from the upstream `python` image itself.

Nothing in this repository can change what Microsoft or Docker put in a base image. Blocking on it
holds back exactly the fixes the rebuild does carry, which is the failure this ADR set out to end.

**Decision.** For each image and architecture, `build-image.yml` also scans the base image the
build is `FROM`, with the same Trivy, database, flags and exceptions as the other two scans. The
reference is the `BASE_IMAGE` build arg the build used, defined once in the job (the mirror on
`main`, the `images.json` `upstream` elsewhere), resolved to its per-arch digest by
`scripts/vuln-baseline.sh --upstream`. [scripts/vuln-gate.sh](../../scripts/vuln-gate.sh) takes it
as `--upstream`, and a fourth class joins the three above:

- **inherited from the base image** (candidate and base image, not the published image): listed,
  does not block.

So what blocks is the candidate minus the published image minus the base image. The identity is
unchanged: (vulnerability id, package name, package type). A finding both the published image and
the base image carry stays *known upstream*, so the inherited list is exactly what the base image
alone excuses. The base-image baseline works with the strict comparison too: a new image is
blocked only for what it adds on top of its base. The gate result JSON gains an `inherited` list
and the base image's reference.

It is additive and best-effort. If the base cannot be resolved or scanned, the gate runs as it
did before this amendment (published comparison, or strict), with a notice saying why; an
unreadable base report that *was* handed to the gate is still a failure, never "no findings". No
new credential: on `main` the mirror is read with the job's existing registry login, elsewhere
the public upstream is read anonymously, and the job token is never offered to another registry.

**Consequences.**

- Whatever a base image ships at a fixed version ships here too, until upstream publishes a fixed
  base. The daily rebuild re-mirrors the base, so the fix arrives the day upstream ships it. It is
  listed as inherited in every gate summary and stays an alert in code scanning meanwhile.
- What the build adds on top of the base (a tool, a pin, a package the Dockerfile installs) is
  judged exactly as before. Since the identity ignores the path, a package the build installs
  that matches one the base already carries with the same advisory is excused too. That is the
  same trade-off as for *known upstream*, and it is accepted for the same reason.
- The base is read after the build, not recorded by it. On `main` the mirror tag was written by
  the same run's mirror job; on a pull request the upstream tag could move in between. That can
  make one run compare with a slightly newer base than it built on, which is a re-run, not a hole.
- Pull requests read the upstream base from Docker Hub or MCR once more per architecture. A rate
  limit there costs the base-image baseline for that run, not the gate.

**Revisit if** a base image's inherited list grows and stays for weeks with fixed releases
available upstream: then the base is not being refreshed, which is a pipeline bug.

## Amendment (2026-10-17): the cooldown fails closed, and has a clock of its own

**Context.** The seven-day cooldown on pin bumps was only as good as the release date it measured
from, and two gaps let a version through on the day it shipped:

- When the date lookup failed — a 404, an API that did not answer, a date that did not parse —
  `bump-pins.sh` logged it and went on, classing the bump `review`. The merge bot does not read
  the class, so a green `review` PR merged the same day. The cooldown failed open.
- The AWS CLI, the Docker static client and gcloud have no release date to measure from at all,
  so they never had a cooldown. They were also the three downloads with no checksum.

A vendor date is also the vendor's to set: whoever controls the download channel controls it, and
a GitHub release whose asset is replaced after publication keeps its old `published_at`.

**Decision.**

- **Unknown is deferred.** A release whose date cannot be established is `deferred` ("release
  date unknown"), every day until it can be read, with a warning annotation on the pin-bump run
  so a broken lookup does not freeze a pin unnoticed.
- **A GitHub release is as old as its newest asset**: the date is the later of `published_at` and
  every asset's `updated_at`, so a re-upload restarts the cooldown. A PyPI release is as old as
  its newest file.
- **A first-seen clock for what has no date.** The pin-bump PR body ends in a marker,
  `<!-- pin-bump: unit=… to=… class=… seen=YYYY-MM-DD fp=… -->`. `seen` is the day pin bump first
  proposed that exact version; `fp` is a digest of every value the bump wrote, the version and
  every sum. The daily rebuild of the branch keeps `seen` while the version and `fp` are
  unchanged, and restarts it when either changes — so an artifact replaced under the same version
  (a different trust-on-first-use hash) starts the week again. While the clock runs the PR keeps
  its version even when the vendor ships a newer one (the AWS CLI releases almost daily; chasing
  each would restart the clock forever), unless the newer one is lower or the base already has
  it. [scripts/merge-bot-prs.sh](../../scripts/merge-bot-prs.sh) will not merge a pin-bump PR
  whose marker is missing or unreadable, and will not merge one not marked `class=auto` before
  `seen` plus seven days. After that it merges on its next run. No step needs a human. Majors wait
  this clock too, on top of their vendor date.
- **Trust on first use for the three with no checksum.** `bump-pins.sh` downloads each
  architecture's artifact when it moves the version and records its sha256 as an `ARG` beside it;
  every build checks the download with `sha256sum --check --strict`. For the AWS CLI it first
  checks AWS's detached signature against the "AWS CLI Team" key in `scripts/keys/aws-cli.asc`,
  which must be exactly the key with AWS's documented fingerprint
  `FB5DB77FD5C118B80511ADA8A6310ACC4672475C`; an expired key is accepted (AWS lets its expiry lapse
  between renewals), a revoked one or any other key is not.
- **The other unhashed installs are hash-pinned too.** The libraries `ci-cloud` swaps into the
  Azure CLI's bundled Python were `>=` floors fetched fresh on every rebuild; they are now exact
  versions with every linux wheel's sha256 in `ci-cloud/az-overrides.txt`, installed with
  `--require-hashes --no-deps --only-binary :all:`, each a pin with PyPI's upload time as its
  release date. zizmor, which ran as `uvx zizmor` in a job that writes to the Security tab, is
  pinned the same way in `.github/zizmor-requirements.txt`.

**Consequences.**

- A tool with no vendor date reaches the images a week after this repository first saw it,
  instead of the same day. A major waits up to two weeks: seven days by its vendor date before it
  is proposed, then seven on its PR.
- A trust-on-first-use sum cannot prove the first download was genuine (except for the AWS CLI,
  whose signature is checked). What it does is pin it: a file substituted after the bump fails
  every build instead of being installed, and a rebuild of the PR's branch inside the cooldown
  that hashes a different file restarts its clock, where the PR shows it.
- An AWS CLI signed by a new key fails its bump, for a person to check the new key and pin it.
- A security fix in one of the Azure CLI's libraries now arrives a week after its release, through
  a pin-bump PR, rather than with the next daily rebuild.

**Revisit if** a vendor starts publishing a checksum or a trustworthy release date for one of the
three: move it to `sums` and its vendor date, and drop the trust-on-first-use row.
