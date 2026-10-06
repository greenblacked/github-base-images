# 0008 — Self-updating: a regression gate, a daily cadence, and merge-when-green

**Status:** accepted; supersedes the absolute vulnerability gate and the failing alerts report of
[0006](0006-gate-on-fixable-library-vulnerabilities.md), and the auto-merge, review and
publishing parts of [0007](0007-automatic-updates.md)

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
finishes, hourly, and on demand. It merges every open `dependabot/*` PR by Dependabot and every
`pin-bump/*` PR by `github-actions[bot]` when all of these hold:

- every commit is the bot's own, by author and committer;
- `CI result`, `Repository secret scan`, `CodeQL (workflows)` and `Dependency review` each have
  their latest GitHub Actions run on the PR's head SHA completed with success;
- the PR merges cleanly;
- it has no `hold` label.

The merge is `gh pr merge --squash --match-head-commit <sha>`. This includes majors and the bumps
labelled `needs-review` (AWS CLI, Docker client, gcloud, and any major). The full build, smoke
tests and gate are the safety net, and the label is information only. After a merge it dispatches
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
