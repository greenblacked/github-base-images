# 0006 — The vulnerability gate fails on fixable library findings too

**Status:** accepted; supersedes the library-vulnerability part of
[0003](0003-gates-vs-reports.md). Partially superseded by [0008](0008-self-updating.md): the gate
now blocks only findings a build adds compared with the published image, and open fixable alerts
are a warning in the alerts report rather than a failure. The scope (`os,library`, fixable,
HIGH/CRITICAL) and the exception rules below still hold.

**Date:** 2026-09-26

## Context

[0003](0003-gates-vs-reports.md) drew the vulnerability gate at OS packages: fixable
HIGH/CRITICAL findings in the Debian (or Ubuntu) layer blocked a publish, and findings in
libraries and binaries were reported only. The reasoning was that library findings are the
runtime's own bundled dependencies, shipped inside the upstream image, and that gating on them
would block every publish on someone else's release schedule.

Two things weakened that line.

- **Not every library finding is upstream's.** The images install and pin their own tools —
  Terraform, kubectl and the Docker client in `ci-tools`, gcloud in `ci-cloud`, the scanners in
  `ci-security`, `migrate` in `ci-db`, Composer — and a fixable CVE in a Go module or other
  dependency compiled into one of those is fixed by bumping a pin in this repository. 0003's own "Revisit if" named this: library findings become actionable once
  an image carries third-party code this repo chose.
- **"Report-only" meant "published anyway".** A fixable HIGH/CRITICAL library finding went out
  in every rebuild, visible in *Security → Code scanning* alongside thousands of unfixed alerts,
  where nothing forced anyone to look. The SARIF view was built to record accepted risk; it was
  also silently holding risk nobody had accepted, because a fix existed.

## Decision

The vulnerability gate in `build-image.yml` fails on **any fixable HIGH/CRITICAL finding**, in OS
packages and in libraries and binaries alike: `vuln-type: os,library`, with `ignore-unfixed: true`
and `severity: HIGH,CRITICAL` unchanged. Unfixed findings stay report-only, wherever they are.

Red must still always mean there is a version to move to; `ignore-unfixed` is what keeps that
true. A fixable library finding is one of two kinds:

- **In a tool this repo installs and pins.** The fix is bumping the pin in `Dockerfile.ci` (with a
  fresh checksum), through the normal PR path.
- **In the upstream runtime image** — the npm, pip or gem packages it bundles. The fix is the
  upstream's patch release, which the weekly rebuild and Dependabot's base-image bumps pick up.

The second kind is the cost 0003 declined, and it is now accepted: **an image can stay red until
upstream ships a patched image**, and the rolling tag stays on the last image that passed. In
exchange, nothing with a known fix at HIGH/CRITICAL is ever published.

Alongside the gate, `alerts-report.yml` reads the open alerts back — code scanning on `main`,
and Dependabot — after every publish run and weekly, and **fails when a fixable HIGH/CRITICAL
alert is still open**: a Trivy alert with a fixed version in an image still in `images.json`, or
a Dependabot alert with a `first_patched_version`. That is the same rule as the gate, applied to
what is already published and to the repository's own dependencies. One open means a gate did
not hold, or an image has not been rebuilt since the fix appeared; either is this repo's to act
on. Unfixed alerts, and alerts left in categories of images that no longer exist, never fail it.

GitHub's secret-scanning alerts are not part of that report. No `GITHUB_TOKEN` permission can read
them, and this repository adds no personal access token or app credential to reach them; the
report says so and links to the page instead of implying it checked.

### Exceptions: expiring, per image, per id

`ignore-unfixed` trusts the advisory's "fixed version". Usually that is the whole story, but not
always: an advisory can name a fixed version of a module that no released artifact this repo could
install contains yet. Go modules compiled into an upstream release binary (`migrate` in `ci-db`,
the scanners in `ci-security`), packages vendored inside pip in the Python images, NuGet packages
inside the .NET SDK, cryptography bundled with the Azure CLI: the gate is red, and
nothing in this repository can turn it green. Muting the gate for those images would hide every
other finding in them as well.

So the gate takes **exceptions** from `.github/vuln-exceptions.json`, under these rules:

- **Only where no released artifact contains the fix.** Never for "a fix exists but the pin has
  not been bumped yet", and never for "a patched upstream image exists but has not been rebuilt":
  those are this repository's to fix, and the gate is right to be red.
- **Per image and per id.** Each entry names one image and one CVE or GHSA id exactly as Trivy
  prints it. `build-image.yml` turns only that image's entries into the Trivy ignore file for that
  image's gate, so an exception can never excuse the same id in another image.
- **Per package, too.** Within the image, every entry is narrowed by `paths`, `purls` or both, and
  `scripts/lint.sh` rejects one with neither, because an id alone would be excused in every
  package of the image. `paths` lists the Trivy target or package path (such as
  `usr/local/bin/migrate`), written out in full, with no leading `/` and no glob characters: the
  same id in any other file of the same image still fails. Where Trivy reports no usable path
  (packages vendored inside pip appear under the aggregate `Python` target), `purls` names the
  package and its exact installed version as Trivy's PURL for the finding
  (`pkg:pypi/msgpack@1.1.2`): the same id in another package, or in another version of the same
  one, still fails. When both are given, a finding must match both.
- **Ninety days at most.** Each entry has an `expires` date, which `scripts/lint.sh` rejects if it
  is more than 90 days away. It becomes the ignore file's `expired_at`, and from that date Trivy
  stops applying the entry: the image goes red again and someone has to look, then remove the
  entry because the fix shipped or renew it with a new date because it still has not. Lint only
  warns about an expired entry, so a date passing never fails an unrelated pull request; the red
  gate is the signal.
- **Always visible.** The gate step prints the exceptions it applied to the log and the job
  summary. The vulnerability reports, SARIF and SBOM never use them, so an excepted finding still
  appears in *Security → Code scanning*. The alerts report applies the same image, id, path and
  package-version matching, lists every excepted alert in an *Active exceptions* section and every
  expired entry as a reminder; the first never fails it, and the second excuses nothing.

Every entry also says why the fix cannot be taken here (`reason`) and where to watch for it
(`upstream`), so renewing one is a decision made with the evidence in front of the reviewer, not a
date bump.

## Consequences

- A green publish now means no fixable HIGH/CRITICAL vulnerability in the image's OS packages
  **or** libraries and binaries. SECURITY.md's scope for reporters says the same.
- An image can be held back by upstream: while its runtime image carries a fixable finding that
  upstream has not yet shipped, that image's rebuilds fail and its tag does not move. Other
  images are unaffected; `digests` still aggregates what published.
- The SARIF report no longer differs from the gate in package scope — both cover `os,library` —
  only in including unfixed findings. It remains the standing inventory of accepted risk.
- The alerts report makes the Security tab something a run can fail on, which it never was.
  That is deliberate and narrow: only what has a fix and should not be open fails it.
- Its Dependabot fetch needs the `vulnerability-alerts: read` token permission, granted both in
  `alerts-report.yml` and in the calling job in `build-and-push.yml` (reusable-workflow
  permissions are the intersection). The actionlint version `scripts/lint.sh` pins predates that
  scope, so `.github/actionlint.yaml` ignores that one message in those two files.
- An exception is a standing cost with a date on it. Each one lapses within 90 days and turns its
  image red again, so the list cannot quietly grow into a second, unreviewed gate configuration;
  the price is a renewal pull request for every finding whose upstream is slow.
- The OSV scan stays report-only. It is a second opinion on packages the Trivy gate already
  judges, through a source-package mapping this repo maintains (0003).

## Revisit if

A gate starts staying red for weeks on one upstream image with no patched release in sight. That
is the cost this record accepted, not a reason to mute the gate — but if it becomes the normal
state for an image, the remedy is a different base or retiring the image
([0005](0005-new-images-current-distro-retire-at-eol.md)), decided explicitly, rather than
narrowing `vuln-type` back to `os`.
