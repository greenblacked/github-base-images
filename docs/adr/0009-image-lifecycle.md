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

**Distribution (amends 0005).** A new image starts on the newest Debian stable whose exact tag
upstream publishes; failing that, the newest Ubuntu LTS whose tag it publishes. The version line is
`<codename>-v1`. So Ubuntu 26.04 "resolute" becomes a new line, `resolute-v1`, with the first image
built on it (Temurin and .NET publish no Debian image, and 26.04 is now the newest LTS). Existing
images never move.

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

**Unknowns are never actions.** If endoflife.date cannot be read, nothing is added, deprecated or
retired for that runtime that day. If the registry errors rather than answering "no such tag", that
line is not added, and the next distribution is not tried either. Both are warnings in the run
summary. "Not yet" is silent.

**Consistency is linted.** `image-lifecycle.sh check` runs in `scripts/lint.sh`: the Dependabot
docker directories, the README catalog rows (with base and tag) and count, and the
`docs/images.md` bullets each equal the `images.json` images; every `ARG BASE_IMAGE` default equals
its entry's `upstream`; the generated parts match `.github/lifecycle.json`. The pin tooling
(`check-pins.sh`, `bump-pins.sh`) and the pin parity check now find which images carry a shared
pin (npm, Playwright, Composer, the json gem) from the Dockerfiles of the `images.json` images, so
adding or retiring an image never needs a change there.

## Why

- **New lines merge themselves, like every other update.** The owner decided this. A new image
  goes through the same build, smoke tests and gate as any change. It is gated strictly, against
  an empty baseline, so it cannot ship a fixable HIGH/CRITICAL finding, and nothing consumes it
  until someone points a workflow at it.
- **Newest Debian stable, else newest Ubuntu LTS** is 0005's rule with its exception made general.
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
- **A lifecycle pull request that is no longer wanted is not closed automatically** (an add
  overtaken by a newer line, a deprecation whose date moved out of the window). It stays open and
  green; close it, and it is not reopened for the same change.
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
