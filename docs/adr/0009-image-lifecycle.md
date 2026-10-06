# 0009 — The image lifecycle runs itself: new lines added, old ones deprecated and retired

**Status:** accepted; amends the distribution rule of
[0005](0005-new-images-current-distro-retire-at-eol.md) and automates both of its rules

**Date:** 2026-10-06

## Context

[0008](0008-self-updating.md) made every *update* to an existing image arrive, merge and publish
without anyone watching. The set of images did not keep itself current. A new runtime line (Python
3.15, Node.js 26, .NET 11) was a directory, an `images.json` entry, a Dependabot entry and a
handful of prose edits that somebody had to make. A line reaching end of support had to be
noticed, announced and removed by hand. [0005](0005-new-images-current-distro-retire-at-eol.md)
set both rules, but only `ci-dotnet8` and `ci-dotnet9` had been through them, by hand. The owner
wants to spend no time on this repository, and these were the last recurring tasks that needed
someone.

Two facts shaped how it is done:

- **Upstream says when, in a form a script can read.** [endoflife.date](https://endoflife.date)
  publishes every runtime's release and end-of-support dates (API v1), including the LTS flags
  and dates Node.js and Java need, and Debian's and Ubuntu's releases. The registries say whether
  a tag exists, and for which architectures: Docker Hub's tag API, and MCR's tag list.
- **Release candidates look like releases in some registries.** `python:3.15-rc-slim-trixie` is
  published long before `python:3.15-slim-trixie`, which is fine. But MCR publishes the floating
  `11.0-resolute` from the first .NET 11 preview on; only a full SDK version tag with no
  pre-release label (`11.0.100-resolute`) says the line is GA.

## Decision

A daily workflow, [image-lifecycle.yml](../../.github/workflows/image-lifecycle.yml), runs
[scripts/image-lifecycle.sh](../../scripts/image-lifecycle.sh) and opens one pull request per
action due. Each merges itself when green, through the merge bot of
[0008](0008-self-updating.md), which now also takes `lifecycle/*` branches by
`github-actions[bot]`, under the same rules as `pin-bump/*`.

**Which images.** The versioned runtime images: Python, Node.js, PHP, Ruby, Java (Temurin) and
.NET. A table in the script maps each family to its endoflife.date product and its upstream tag
shapes. `ci-go` and `ci-rust` are exempt (they track current stable on a floating `1-<codename>`
tag, and have no lines), as are the tool images.

**Add.** A cycle is added when it is newer than the family's newest image, released, not past
end of support, and its exact tag is published for `linux/amd64` and `linux/arm64`. Node.js only
for even majors, once their LTS date has passed. Java only for LTS releases. .NET for every
release, STS included. Older lines are never added (no backfill), and nothing before GA: an RC tag
alone, or an MCR floating tag with no GA SDK tag, is "not yet". The image is
`ci-<family><version without dots>`, copied from the family's newest image (skipping one that
carries a line-specific workaround, such as `ci-ruby40`'s json gem replacement), with the version,
base, description, distribution and version assertions rewritten.

**Distribution (amends 0005).** Exactly two candidates are probed, in order: the newest
released Debian stable, then the newest released Ubuntu LTS. A new image starts on the first whose
exact tag upstream publishes for both architectures. No older release of either is ever tried: if
neither has the tag yet, the line waits (a notice in the run each day) until one does. The Ubuntu
candidate exists only for the families whose upstream publishes Ubuntu images (Temurin and .NET);
Python, Node.js, PHP and Ruby wait for the Debian tag. The version line is `<codename>-v1`.

So where each family lands depends on what upstream publishes when the line goes GA, not on a
fixed rule per family. Temurin publishes no Debian tag, so Java 29 will start on the newest
Ubuntu LTS: today that is 26.04 "resolute", a new line, `resolute-v1`. .NET is probed for a Debian
`-slim` SDK tag first (`11.0-trixie-slim`). Microsoft has published none since .NET 10 (as of
today the only Debian or Ubuntu .NET 11 tag on MCR is `11.0-resolute`), so .NET 11 is expected on
`resolute-v1` too, but it starts on `trixie-v1` if Microsoft publishes a Trixie image by then.
Existing images never move.

**Deprecate.** From 120 days before upstream end of support. End of support is endoflife.date's
`eolFrom`: the end of security fixes, not the end of active support. The deprecation is recorded
in [.github/lifecycle.json](../../.github/lifecycle.json), and the catalog marker, the README and
SECURITY.md notices and the docs section are generated from it. The record is what makes the
detection idempotent: an image already recorded with the same date is not announced again (the
existing `ci-dotnet8` and `ci-dotnet9` notice is recorded there). A date that moves upstream is a
new deprecation pull request with the new date.

**Retire.** After end of support, and no sooner than 30 days after the deprecation reached `main`.
The directory, its `images.json`, Dependabot and vulnerability-exception entries and its catalog
row go; usage examples that pull it point at its successor; the docs keep a *Retired* note under
the anchor the notice had, so links to it keep working. An image past end of support that was
never announced is announced first.

**What stops being due is closed, by the bot, never on an outage.** Each run closes any open
lifecycle pull request whose change is no longer in its plan (a retirement whose end of support
moved into the future, an add whose line upstream withdrew), with a comment saying why, the
`lifecycle-superseded` label, and its branch deleted. It does so only for a runtime whose plan
that day was complete; an unreadable source, or any warning for that runtime, closes nothing. A PR
someone else committed to is left open, with a warning. Closing is a veto only when a person did
it: a PR the bot closed (labelled) does not stop a fresh one when the change is due again, and a
PR whose labels cannot be read counts as a person's veto. Between a retirement ceasing to be due
and the next daily run, the merge bot itself refuses a `lifecycle/retire-*` PR unless the
end-of-support date in its marker has passed and `main`'s `.github/lifecycle.json` still records
that date; no marker, or a record it cannot read, is not merged.

**Unknowns are never actions.** If endoflife.date cannot be read, nothing is added, deprecated or
retired for that runtime that day. If the registry errors rather than answering "no such tag", that
line is not added, and the next distribution is not tried either. Both are warnings in the run
summary. "Not yet" is not a warning, but it is not silent either: a line endoflife.date calls GA
whose tag is on neither distribution yet is a `::notice::` in the run, and listed in its summary,
every day it waits.

**Consistency is linted.** `image-lifecycle.sh check` runs in `scripts/lint.sh`: the Dependabot
docker directories, the README catalog rows (with base and tag) and count, and the
`docs/images.md` bullets each equal the `images.json` images; every `ARG BASE_IMAGE` default equals
its entry's `upstream`; the generated parts match `.github/lifecycle.json`. The pin tooling
(`check-pins.sh`, `bump-pins.sh`) and the pin parity check now find which images carry a shared
pin (npm, Playwright, Composer, the json gem) from the Dockerfiles of the `images.json` images, so
adding or retiring an image never needs a change there.

### Merge bot trigger

This also corrects how [0008](0008-self-updating.md)'s merge bot is started, observed on the day
this was written. 0008 relied on `workflow_run` (when Build and Push or Security finishes) plus an
hourly schedule. Neither worked for the bot pull requests:

- **`workflow_run` does not follow a run that a `GITHUB_TOKEN` dispatch started.** Every
  `pin-bump/*` and `lifecycle/*` branch, and every refreshed `dependabot/*` branch, gets its CI
  that way (a push made with the token starts nothing), so the merge bot never heard that their
  checks had finished. A run Dependabot itself started is skipped on purpose (its token is
  read-only).
- **The hourly schedule did not run at all** in the first two hours after it reached `main`;
  GitHub delays and drops scheduled runs under load. Green bot PRs waited until someone started
  the merge bot by hand.

So, within `GITHUB_TOKEN` (a dispatch made with it does start a run):

- Build and Push and Security end with a `request-merge` job, after every other job and whatever
  their result, that dispatches the merge bot on `main` when the run was a dispatch on a
  `pin-bump/*`, `lifecycle/*` or `dependabot/*` branch. Whichever finishes second finds all four
  checks complete. Its only permission is `actions: write`; it checks nothing out.
- The scheduled rebuild on `main`, pin bump and image lifecycle dispatch the merge bot at their
  end: three daily backstops that do not depend on cron.
- The hourly schedule and `workflow_run` stay. Dependabot PRs rely on the hourly run and the daily
  backstops, since their own CI cannot dispatch anything.

## Why

- **New lines merge themselves, like every other update.** The owner decided this. A new image
  goes through the same build, smoke tests and gate as any change. It is gated strictly, against
  an empty baseline, so it cannot ship a fixable HIGH/CRITICAL finding, and nothing consumes it
  until someone points a workflow at it.
- **Newest Debian stable, else newest Ubuntu LTS, and nothing older** is 0005's rule with its
  exception made general.
  0005 named Noble because it was the newest LTS. Tying the rule to "newest" instead of a codename
  is what stops the next image starting on migration debt, and it needs no edit when Debian 14 or
  Ubuntu 28.04 ships.
- **Node.js once LTS, Java LTS only, .NET all lines.** Those are the lines each upstream supports
  for long enough to build on. An odd Node.js major and a non-LTS Java are supported for about six
  months, less than a consumer's migration. Every .NET release, STS included, is supported for 18
  months or more.
- **120 days and 30 days.** 120 days gives a consumer a release cycle of their own to move. The
  30-day floor means a retirement is never the first thing a consumer hears, even if a date
  moves or the workflow was paused past one.
- **A state file, not a parsed marker.** The README is prose that people edit; a JSON record is
  not ambiguous, and it is not a pipeline file, so a deprecation pull request builds nothing.
- **Unknown is never acted on.** A false add is an image someone has to remove; a false retirement
  stops security rebuilds of an image people use. Waiting a day costs nothing.

## Consequences

- **One step stays manual: package visibility.** GHCR creates a new package private, and
  `GITHUB_TOKEN` cannot change that. GitHub's REST API for packages has no endpoint that changes
  visibility at all (its package endpoints list, get, delete and restore). The add pull request
  says so, and [docs/images.md](../images.md#visibility-and-authentication) has the step. Until
  then pulls from other repositories fail with `denied`, and the published-image audit reports the
  package. A new line reuses its runtime's existing `mirror-*` package, so only the `ci-*` package
  needs it.
- **Deleting a retired package stays manual** too, as in 0005; the retire pull request says so.
- **An add pull request rebuilds every image**, since it changes `images.json`. A retirement does
  too. A deprecation builds nothing.
- **A new image can be held up by upstream.** Against an empty baseline every fixable finding
  blocks. The script copies the sibling's unexpired package-scoped vulnerability exceptions (same
  expiry, never extended), which covers what upstream already carried in the sibling. Anything new
  keeps the pull request red. It waits, rebuilt from `main` daily, until upstream fixes it or
  someone adds an exception.
- **Prose that names a specific image** outside the generated parts (an example, a comparison)
  is not rewritten by the add, and only full image references are moved to the successor by the
  retirement. Such mentions go stale until someone edits them.
- **A lifecycle pull request that is no longer due is closed by the next daily run** (an add
  whose line was withdrawn, a retirement or deprecation whose date moved), labelled
  `lifecycle-superseded`, its branch deleted. Until then the merge bot refuses a retirement that
  `main`'s record no longer supports. So is an add overtaken by a newer line of the same runtime
  that merged first: the older line is no longer newer than the newest image (no backfill).
- Several retirements due on the same day are separate pull requests that touch neighbouring lines,
  so the second conflicts once the first merges; the next daily run rebuilds it from `main`.

## Revisit if

- GitHub adds an API, or a repository setting, for package visibility: the manual step goes.
- endoflife.date stops publishing a product, changes its API version, or proves wrong for one: the
  family table can point a family at another source.
- An upstream starts publishing images for a family on a distribution this rule would not pick, or
  stops publishing for one it would (for example Temurin publishing Debian tags).
- Two lines of a runtime need to be added at once often enough that the one-pull-request-per-image
  rhythm is noise.
