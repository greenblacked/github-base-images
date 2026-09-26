# 0006 — The vulnerability gate fails on fixable library findings too

**Status:** accepted; supersedes the library-vulnerability part of
[0003](0003-gates-vs-reports.md)

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
- The OSV scan stays report-only. It is a second opinion on packages the Trivy gate already
  judges, through a source-package mapping this repo maintains (0003).

## Revisit if

A gate starts staying red for weeks on one upstream image with no patched release in sight. That
is the cost this record accepted, not a reason to mute the gate — but if it becomes the normal
state for an image, the remedy is a different base or retiring the image
([0005](0005-new-images-current-distro-retire-at-eol.md)), decided explicitly, rather than
narrowing `vuln-type` back to `os`.
