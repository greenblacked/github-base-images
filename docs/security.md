# Security

What is checked before an image is published, what is only reported, and how to verify what was
published. The README's
[What a green publish guarantees](../README.md#what-a-green-publish-guarantees) is the one-table
summary; this page is the detail. Reporting a vulnerability is covered by
[SECURITY.md](../SECURITY.md).

- [Tests and security scanning](#tests-and-security-scanning): the smoke test, the five Trivy
  scans, the Security tab, and OSV
- [Vulnerability exceptions](#vulnerability-exceptions): the one way past the vulnerability gate
- [Verifying a signature](#verifying-a-signature), with cosign or
  [the GitHub CLI](#or-with-the-github-cli)
- [Attestations](#attestations)
- [Repository security checks](#repository-security-checks)
- [Required checks](#required-checks)
- [Security alerts report](#security-alerts-report)
- [Supply-chain pins](#supply-chain-pins)

The reasoning behind the gate/report split is recorded in
[ADR 0003](adr/0003-gates-vs-reports.md),
[ADR 0006](adr/0006-gate-on-fixable-library-vulnerabilities.md) and
[ADR 0008](adr/0008-self-updating.md).

## Tests and security scanning

Nothing is pushed until the image has been built, smoke-tested, and scanned. Verification is
CI-driven: open a PR and the pipeline runs the whole stack; a green PR run is the pre-merge proof.

Each `<image>/test.sh` asserts every tool the image promises is present
(`--no-install-recommends` is exactly how one silently goes missing), that TLS verification
actually works, and that nothing project-specific — dependencies, credentials, state — is baked
in.

Trivy runs five scans on every build, per architecture. All reports are printed to the log and
uploaded as a **`security-report-<image>-<arch>` artifact** (retained 90 days), including on failed
builds. The job summary lists them and carries the gate's own table; the full tables are too large
for it (a step summary is capped at 1 MiB):

- **Vulnerability scan** — full report at every severity, and **a gate that blocks the push** when
  the build **adds** a **fixable** HIGH/CRITICAL finding, in OS packages *and* in libraries and
  binaries (Go binaries, npm, pip, gem, jar, …) — `vuln-type: os,library`. How it decides:
  - It scans the candidate and the image published now for the same tag and architecture (its
    per-arch digest), with the same Trivy, the same database and the same flags, and compares them
    by vulnerability id, package and package type (`debian`, `node-pkg`, `python-pkg`, …)
    ([scripts/vuln-gate.sh](../scripts/vuln-gate.sh)). A finding
    only the candidate has is **new** and blocks. One both have is **known upstream** and is
    listed. One only the published image has is **fixed by this build** and is listed. The same CVE
    in the same package at a newer version is still known; the same CVE in an npm package that shares
    a name with a known Debian package is not.
  - With nothing to compare against (a new image or a new tag), or when the published image cannot
    be read (after three retries) or scanned, it runs **strict**: every finding blocks, and the summary says why. An
    unreadable report fails the gate. It is never read as "no findings".
  - `ignore-unfixed` keeps it honest: red always means there is a version to move to, never a CVE
    with no patch available. Unfixed findings are reported, not enforced.
  - **Known upstream findings ship until upstream fixes them.** That is the case for a package
    vendored inside another (pip's urllib3, npm's undici, the libraries inside the Azure CLI) whose
    advisory names a fixed version that no release contains yet. Blocking the rebuild over them
    would only withhold the Debian updates and other fixes it carries. They close on their own when
    the daily rebuild or an automated update picks up the fixed release.
    [ADR 0008](adr/0008-self-updating.md) records why the gate stopped being absolute;
    [ADR 0006](adr/0006-gate-on-fixable-library-vulnerabilities.md) why libraries are in scope.
  - A finding a build adds can only get past the gate through an **expiring exception** in
    `.github/vuln-exceptions.json`, for a finding whose fixed version is in no released artifact
    yet (a module compiled into the latest upstream release binary, a package vendored inside pip).
    Exceptions are per image, per CVE and per path or package version, last 90 days at most, apply
    to both scans, and are printed in the gate step's log and summary. The reports and SARIF above
    never use them. See [Vulnerability exceptions](#vulnerability-exceptions).
  - Both scans and the decision are kept as the `vuln-gate-<image>-<arch>` artifact.
- **Secret scan** — **gates at any severity**. A baked-in credential in a public CI image is
  always fixable from this repo, with no upstream to wait on, so there is no excuse for shipping
  one.
- **Misconfiguration scan** — lints the Dockerfile's build instructions (missing `USER`, `ADD` vs
  `COPY`, …). Best-practice guidance rather than exploitable findings, so it is **reported, not
  gating** — the gates stay reserved for real, fixable security problems.
- **License scan** — the license of every OS package and bundled library in the image. **Reported,
  not gating**: a copyleft finding in Debian's own packages is information a consumer may need, not
  something fixable from here.
- **SBOM** — a CycloneDX bill of materials per image and architecture
  (`sbom-<image>-<arch>.cdx.json`, in the same artifact). This is what lets a consumer answer *"was
  I affected by X"* months later without rebuilding or re-scanning the image.

### The Security tab

The vulnerability scan is also emitted as **SARIF and uploaded to the repository's Security tab**,
under a `<image>-<arch>` category, so findings are browsable and diffable over time rather than
buried in a build log. The upload is `continue-on-error` — code scanning must never be the reason
an image fails to publish.

**Its scope is deliberately wider than the gate's, so expect this view to be non-empty.** The gate
blocks only what has a fix; the SARIF exists to record what the gate lets through rather than
duplicate what it blocks:

- **No `ignore-unfixed`.** On an image whose build just ran `apt-get upgrade`, "fixed" and
  "already applied" are close to the same set — a fixed-only report on a freshly rebuilt image is
  close to a guarantee of nothing. What is left is overwhelmingly *unfixed* HIGH/CRITICAL CVEs,
  which is exactly the accepted risk worth a standing record.
- **The same package scope as the gate**: OS packages and libraries, including the runtime's own
  bundled `pip`, `npm` and `gem` packages baked into the upstream image. Their unfixed CVEs never
  gate, but a consumer of the image has every reason to want to know what those bundled versions
  carry.
- **Severity stays HIGH,CRITICAL**, via `limit-severities-for-sarif: true` alongside `severity:`.
  Without that flag trivy-action silently ignores `severity:` for SARIF output and ships every
  severity, UNKNOWN and LOW included — see the comment at the step itself, and
  [ADR 0003](adr/0003-gates-vs-reports.md) for why that flag exists at all.

So *Security → Code scanning* is where you look for what this repo has decided is safe to ship
without blocking: unfixed OS and library CVEs at HIGH/CRITICAL, browsable and diffable across
builds. It is accepted risk, not a build failure — nothing here means the pipeline is broken. For
the exhaustive picture (every severity, every scanner, unfixed and fixed alike) go to the job
summary or the `security-report-<image>-<arch>` artifact, which run with no filters at all.

### A second opinion from OSV

After both architectures build, a separate `osv` job runs
[osv-scanner](https://github.com/google/osv-scanner) over the CycloneDX SBOM the build already
produced — no second image scan — and uploads the result to the Security tab under its own
`osv-<image>-<arch>` category, next to Trivy's. OSV aggregates the Debian and Ubuntu security
trackers alongside the npm, PyPI, RubyGems and Go advisories, so it is a different database
looking at the same packages. **Reported, not gating.** Like the Trivy SARIF, the upload is
limited to HIGH/CRITICAL (`security-severity` >= 7.0) — plus every finding OSV gives no score at
all, which are kept rather than silently dropped. The unfiltered report, every severity, is the
`osv-report-<image>-<arch>` artifact; the job summary gives the kept / dropped / unscored counts.

Four things about it are less obvious than they look:

- **It fails when it could not look.** Findings are success. A scan that did not complete — the
  OSV database unreachable, no packages read from the SBOM, the binary not running — turns the
  job red, and its SARIF is deleted rather than uploaded. osv-scanner writes a valid, zero-result
  SARIF even when it could not reach its database; uploading that would be an empty report posing
  as a clean one. Being its own job, an outage there never holds up a publish or the
  [`digests.json` aggregate](pipeline.md#digests-and-digestsjson) — the run goes red, and that is
  all.
- **The SBOM is normalised first.** As Trivy writes it, it matches nothing in OSV's Debian data:
  the purl says `distro=debian-12.15` where OSV files under `Debian:12`, and it names binary
  packages (`libc6`) where OSV keys by source (`glibc`). `scripts/osv-scan-sbom.sh` rewrites a
  copy from the source-package properties Trivy records; on `debian:bookworm-slim` that is the
  difference between 0 findings and 98. The SBOM artifact itself is untouched. If those
  properties ever stop appearing (a Trivy rename), the scan fails instead of quietly falling back
  to binary names; the summary shows how many packages were mapped each way.
- **Alerts stay put between runs.** osv-scanner fingerprints each finding by vulnerability,
  package *and file path*, so the normalised copy is always written to the same path
  (`/tmp/osv-scan-sbom/<sbom name>`) and the displayed location is rewritten to the SBOM's name.
  A per-run temp path would have closed and reopened every alert on every build.
- **Kernel findings on kernel headers stay out of the Security tab.** Images that keep a C
  toolchain (ci-go, ci-php84, ci-php85) carry `linux-libc-dev`, the kernel's userspace headers,
  and OSV files every kernel CVE under its source package `linux`: about 2,000 alerts per image
  and architecture, against a package with no kernel code in it. A container runs the host's
  kernel. When `linux-libc-dev` is the only package from that source, those findings are left out
  of the upload and counted in the summary. They stay in the artifact. If anything else from the
  `linux` source is present, nothing is left out.

```bash
./scripts/osv-scan-sbom.sh sbom-ci-tools-amd64.cdx.json full.sarif upload.sarif   # locally
```

## Vulnerability exceptions

`.github/vuln-exceptions.json` is the only way past the vulnerability gate, and it is narrow on
purpose ([ADR 0006](adr/0006-gate-on-fixable-library-vulnerabilities.md#exceptions-expiring-per-image-per-id)).
Since [ADR 0008](adr/0008-self-updating.md) an entry is needed only for a finding a build *adds*
(one the published image already carries is known upstream and does not block). It is for a
finding whose advisory names a fixed version that **no released artifact contains yet**: a Go module compiled into the latest release of a binary the image installs, a
package vendored inside the upstream image's pip, a package inside the newest .NET SDK. It is
never for "a fix exists and nobody has bumped the pin", nor for "upstream has shipped a patched
image and this one has not been rebuilt" — those get fixed, not excepted.

### File format

JSON has no comments, so the file's format lives here. It is an array of entries:

```json
{
  "image": "ci-db",
  "id": "CVE-2026-56854",
  "package": "golang.org/x/crypto",
  "installed": "v0.53.0",
  "reason": "Compiled into the golang-migrate v4.20.1 release binary, the latest release, ...",
  "upstream": "https://github.com/golang-migrate/migrate/releases",
  "expires": "2026-10-26",
  "paths": ["usr/local/bin/migrate"]
}
```

- `image` is an image in `images.json`; `id` is the CVE or GHSA id exactly as Trivy prints it. One
  entry per image and id: the same CVE in two images is two entries, and the same CVE in two
  files of one image is one entry with both paths.
- `reason` is one sentence on why this repository cannot take the fix now; `upstream` is where to
  watch for it (a release page, a tracking issue, a vendoring file).
- `expires` is `YYYY-MM-DD`, at most 90 days from the day it is written. From that date the entry
  no longer applies — Trivy's `expired_at` semantics — to either scan.
- Every entry needs `paths`, `purls` or both, so it is limited to one package rather than the id
  anywhere in the image. When both are given, a finding must match both.
- `paths` is the Trivy target (`usr/local/bin/migrate`) or package path (a `.deps.json`,
  `…dist-info/METADATA` or `.gemspec` file) the entry is limited to, written out in full as Trivy
  reports it: no leading `/`, no glob characters. Use it whenever the gate table, its *Report
  Summary* or the JSON report shows a stable path.
- `purls` is for findings with no usable path (pip's vendored packages appear under the aggregate
  `Python` target): the package's PURL as Trivy prints it in the JSON report's `PkgIdentifier`,
  `pkg:<type>/<name>@<version>`, for example `["pkg:pypi/msgpack@1.1.2"]`. It pins the exact
  installed version, so the entry stops applying when the package changes.

### Adding and renewing

**Adding one.** Take the ids from the failing gate step's table — all of them, both
architectures — and check that no release of the thing that bundles them carries the fix yet.
Add one entry per image and id, then run `./scripts/lint.sh`, which checks every field, rejects
an unknown image, a malformed id, date, path or PURL, an entry with neither `paths` nor `purls`, a
duplicate, or an expiry more than 90 days out. A change to the file rebuilds exactly the images
whose entries changed, on the pull request and again on `main`, and each gate step prints the
Trivy ignore file it was given in its log and job summary.

**When one expires.** `build-image.yml` warns about the expired entry by name, lint warns
(without failing), and the [alerts report](#security-alerts-report) lists it under *Expired
exceptions*. If the published image already carries the finding, the gate counts it as known
upstream and nothing breaks; only a build that adds it anew is blocked. Check `upstream`: if the fix has shipped, take it (bump the
pin, rebuild) and delete the entry; if it still has not, renew it with a new `expires` and, if
anything changed, a new `reason`. Delete an entry as soon as the finding is gone, even before it
expires.

## Verifying a signature

Every published manifest list is signed with keyless cosign — no key to distribute, no key to
leak. The identity in the certificate is the workflow that built it, and checking that identity is
the whole point: a signature you never verify protects nobody, which is why the recipe is written
down here and in the README.

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp \
    '^https://github\.com/greenblacked/github-base-images/\.github/workflows/build-image\.yml@refs/heads/main$' \
  ghcr.io/greenblacked/ci-tools:bookworm-v1
```

**Do not drop the identity flags.** `cosign verify` without them checks only that *somebody*
signed the image, which any attacker with a Sigstore account can also do. The pair above is what
ties the artifact to this repository's `main`.

The identity is `build-image.yml`, not `build-and-push.yml`. Signing happens inside the reusable
workflow, and a reusable workflow signs under its own path — a common surprise, and the usual
reason a first `cosign verify` fails. If yours does, print what the signature actually claims
rather than guessing:

```bash
cosign verify --insecure-ignore-tlog=false \
  --certificate-identity-regexp '.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/greenblacked/ci-tools:bookworm-v1 2>&1 | head
```

That accepts any identity, so it is a diagnostic, **not** a verification — never leave it in a
pipeline.

Verification belongs in the job that consumes the image, not only in documentation. Pin the digest
from [`digests.json`](pipeline.md#digests-and-digestsjson), verify it, then run it: a tag can move,
and a digest that was signed last week is still the digest that was signed.

The pipeline runs this same check on itself. Straight after signing, the merge job verifies the
signature under exactly the identity above and confirms the SBOM and provenance attestations are
on the index (`scripts/check-published.sh --ref`, the same code as the
[post-publish audit](../.github/workflows/published-audit.yml)), and repeats the check once the
GitHub attestation below has been attached, against the index exactly as consumers see it. A
signature that stops verifying — a renamed workflow, a changed ref — fails the run that caused it,
rather than surfacing from the scheduled audit. A check that could not run fails too, with its own
message; it is never read as a pass.

### Or with the GitHub CLI

Each published index also carries a **GitHub build provenance attestation**, generated by
[`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance) in the
same job that runs cosign. It is independent of the cosign signature — a second verification
path, not a replacement:

```bash
gh attestation verify oci://ghcr.io/greenblacked/ci-tools:bookworm-v1 \
  --repo greenblacked/github-base-images \
  --cert-identity https://github.com/greenblacked/github-base-images/.github/workflows/build-image.yml@refs/heads/main
```

The identity is the same as cosign's, for the same reason: the attestation is signed inside the
reusable workflow. `--repo` alone would accept an attestation from *any* workflow in this
repository; `--cert-identity` pins it to `build-image.yml` on `main`. The pipeline runs this
exact command against every index it attests and fails if it does not verify.

## Attestations

Published images carry an **SBOM and provenance attestation** attached to the artifact itself, not
just to a build artifact that expires after 90 days. These are the `unknown/unknown` entries in:

```bash
docker buildx imagetools inspect ghcr.io/greenblacked/ci-ruby34:bookworm-v1
```

`sbom: true` and `provenance: mode=max` are set on the push step only — the test build uses the
docker exporter via `load:`, which cannot carry attestations. `imagetools create` preserves them
into the final multi-arch index.

The GitHub attestation above is a third, separate record: SLSA build provenance for the index
digest, signed through Sigstore with the workflow's OIDC identity, stored with GitHub's attestation
API and also pushed to GHCR next to the image. It adds to the buildx attestations and the cosign
signature; neither was changed.

On SLSA, precisely: GitHub describes artifact attestations on their own as meeting SLSA v1.0
**Build Level 2**, and notes that generating them in a reusable workflow *can* provide the
isolation **Build Level 3** asks for. Signing here does happen in a reusable workflow
(`build-image.yml`), but that workflow lives in the same repository as its caller and is
changed through the same pull requests, so it is not the separately controlled builder that
argument assumes. This repository makes no SLSA level claim beyond what the attestations
themselves state.

## Repository security checks

[security.yml](../.github/workflows/security.yml) scans the **repository**, where
`build-and-push.yml` scans the **images**. That is a different threat model: anyone who can
influence a workflow file controls every image this repo publishes, without touching a Dockerfile.
It is a separate workflow so a finding can never block an image build, and so it still runs on
days when no image directory changed — `build-and-push.yml` is path-filtered, this is not. It runs
daily, on every push and pull request, and on a dispatch.

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
- **Token permissions** — not a scan but the posture the scans check for. Every workflow declares
  `permissions: {}` at the top level and every job opts back in to exactly the scopes it needs, so
  a job added without a `permissions:` block gets nothing and fails loudly rather than inheriting
  the repository default. That matters most in the two build workflows, which are the ones holding
  `packages: write` and `id-token: write`.
- **Dependency review** — on pull requests, GitHub's
  [dependency-review-action](https://github.com/actions/dependency-review-action) checks what the
  PR *adds* to the dependency graph — in this repository, mostly action versions — against the
  advisory database. **Gates** at `fail-on-severity: high`: the fix is always available here (do
  not merge that version), and a review that could not run at all fails rather than passes. The
  OpenSSF Scorecard lookup it would otherwise make for each changed dependency, against
  `api.deps.dev` and `api.securityscorecards.dev`, is switched off, so it talks only to GitHub.
  It also runs when the workflow is dispatched on a branch other than `main`, comparing `main`
  with the dispatched commit. That is how the automated bump PRs, and a Dependabot branch the merge
  bot brought up to date, get a real review: their pushes come from the workflow token, which
  starts no `pull_request` run, so their checks come from a dispatch
  ([Automatic updates](pipeline.md#automatic-updates)). Without it the job would be
  skipped there, and a skipped job satisfies a required check without having looked.
- **OpenSSF Scorecard** — branch protection, token permissions, pinned dependencies, dangerous
  workflow patterns. Produces the score behind the README badge. Runs on `main` only, since several
  checks inspect repository settings rather than the tree, and the action refuses any other ref.

Four of these publish SARIF to the Security tab — everything above except the git-history scan,
whose findings are deliberately kept out of a view people triage to empty, and dependency review,
whose verdict is the PR check itself. So *Security → Code scanning* collects repository secrets,
workflow findings, the CodeQL results and the Scorecard result. Image vulnerabilities are uploaded
there too, under their own `<image>-<arch>` and `osv-<image>-<arch>` categories — but unlike these
repository-level scans, those are expected to be **non-empty** on a healthy build; see
[The Security tab](#the-security-tab) and [OSV](#a-second-opinion-from-osv) above on why, and what
it means when they are not.

> **First run:** the Scorecard badge stays grey until the workflow has run once on `main` and
> published its results. Both badges track `main`, so they will not reflect a pull request.

## Required checks

These four checks are what a pull request is merged on. The merge bot reads them itself on each
automated PR's head commit ([Automatic updates](pipeline.md#automatic-updates)), so it does not
depend on the ruleset. The `main` ruleset (Settings → Rules → Rulesets → `main`) should require
the same four for human pull requests:

| Check | Workflow | What it covers |
|---|---|---|
| `CI result` | Build and Push to GHCR | lint, plan, and every image the PR builds: build, smoke test, both gates, OSV |
| `Repository secret scan` | Security | committed credentials in the working tree |
| `CodeQL (workflows)` | Security | CodeQL `actions` analysis (reports findings to the Security tab; red when the analysis cannot run) |
| `Dependency review` | Security | new dependencies with HIGH/CRITICAL advisories |

The per-image jobs can't be required by name, because which of them exist depends on the images a
PR touches, and a required check that never reports blocks the PR forever. `CI result` is the one
fixed name that stands for all of them. It always runs, and fails if any job that ran failed or
was cancelled. `Git history secret scan` and `Workflow security audit` are left out: both run their
scanner with `continue-on-error`, so they stay green even when the scan did not run, and requiring
them would add checks that cannot go red. For the same reason Build and Push is not path-filtered
on pull requests: a PR that touches no image and no pipeline file runs lint and builds nothing,
instead of not running at all.

The merge bot merges an automated PR only when the latest GitHub Actions run of each of the four
has completed with success on its head commit. Missing, still running, skipped, neutral,
cancelled, failed or unreadable all mean it waits.

## Security alerts report

*Security → Code scanning* holds thousands of alerts across every image, architecture and tool,
and at that volume the list says how many and little else.
[alerts-report.yml](../.github/workflows/alerts-report.yml) turns it into one report: every open
code-scanning alert on `main` plus every open Dependabot alert, analysed by
[scripts/alerts-report.sh](../scripts/alerts-report.sh). The report has:

- totals by tool and severity;
- a row for **every** image in `images.json`, including those with no alerts: Trivy critical and
  high, how many are fixable, how many are excepted, OSV count, and which architectures have
  alerts;
- every **fixable** HIGH/CRITICAL Trivy alert in full: image, architecture, package, installed and
  fixed version, CVE, and a link;
- **active exceptions**: every fixable HIGH/CRITICAL Trivy alert covered by an unexpired entry in
  [`.github/vuln-exceptions.json`](#vulnerability-exceptions), with its expiry and reason, and
  every **expired** entry, as a reminder to remove or renew it;
- every open Dependabot alert: package, ecosystem, manifest, severity, GHSA/CVE, vulnerable range,
  first patched version;
- the 25 CVEs that affect the most images, which is how a shared-base problem shows up;
- repository-level alerts (CodeQL, zizmor, Scorecard, the repository secret scan), grouped by tool
  and rule;
- **stale** categories: alerts uploaded for images that no longer exist (`ci-go125`, `ci-rust185`,
  …). Nothing will upload there again, so they never close on their own; delete the category under
  *Security → Code scanning → Tool status*.

It runs after every publish run on `main` (the `alerts` job in `build-and-push.yml`), daily, and
on demand via *Run workflow*. Read it on the run's summary page; the full
`report.md`, with the raw `code-scanning.json` and `dependabot.json` it was built from, is the
`code-scanning-report` artifact (90 days). A very large report is cut in the summary, section by
section, never in the artifact.

**Open fixable alerts are a warning, not a failure.** A fixable HIGH/CRITICAL Trivy alert in a
current image is usually *known upstream*: inherited from a runtime image or a vendored package,
with no release that fixes it yet. It ships until one does
([ADR 0008](adr/0008-self-updating.md)). Failing on it would keep `main` red for weeks over
something nothing here can change. So the run shows a warning with the count, and every such alert
is listed in the report. A HIGH/CRITICAL Dependabot alert with a patched version is treated the
same way; Dependabot's own pull request for it merges itself once green. Unfixed findings, stale
categories and alerts covered by an active exception (listed and counted separately) are not
counted at all; an expired entry excuses nothing.

It does fail, rather than reporting zero, whenever it could not look: an API call that failed,
Dependabot alerts switched off for the repository (turn them on under *Settings → Code security*),
input that does not parse (the exceptions file included), or an alert whose fixability it cannot
read. None of those is a routine state, and a report that said "nothing open" because it did not
look is the failure it exists to prevent. It never runs on a pull request, so it is never part of
the `CI result` a pull request is merged on.

```bash
./scripts/alerts-report.sh code-scanning.json dependabot.json .github/images.json \
  .github/vuln-exceptions.json report.md
# exit 0 clean, 3 fixable HIGH/CRITICAL open and not excepted (the workflow warns),
# 1 could not produce a trustworthy report, 2 usage
```

**Not covered: GitHub secret scanning.** No `GITHUB_TOKEN` permission can read secret-scanning
alerts, and this repository adds no personal access token or app credential to reach them, so the
report says so in its own section and links to *Security → Secret scanning* for a manual look.
Secrets are covered in CI by the Trivy secret gate on every image, the Trivy secret scan of the
working tree (which gates), and the gitleaks scan of the git history (reported, in its job log).

The Dependabot fetch needs the `vulnerability-alerts: read` token permission, which is separate
from `security-events`. The pinned actionlint predates that permission, so
`.github/actionlint.yaml` ignores that one message, in those two workflow files only.

## Supply-chain pins

Every action is pinned by commit SHA ([ADR 0004](adr/0004-sha-pinned-actions.md)), and every
downloaded binary — the tools in the images and each lint engine — is checksum-verified wherever
the vendor publishes a checksum; the few that are not are labelled, and listed in
[CONTRIBUTING.md](../CONTRIBUTING.md#what-does-not-belong-in-an-image). The upstream base itself is
copied into GHCR by digest and verified
([Mirrored upstream base](pipeline.md#mirrored-upstream-base)).

Dependabot keeps action pins and base images current with a seven-day `cooldown` on every
ecosystem: nothing is adopted the day it ships, since the window between publication and discovery
is exactly when a same-day bump would pull in a compromised release. The pinned release binaries
Dependabot cannot see are compared against their vendors daily by the pin-drift job, which opens
a tracking issue rather than failing a build. Both are described in full under
[Pin drift](pipeline.md#pin-drift). The pin-bump job then turns that drift into pull requests, with
checksums taken only from the vendor's published files and the same seven-day cooldown. Its pull
requests and Dependabot's merge themselves once every required check passes, and publish straight
away ([Automatic updates](pipeline.md#automatic-updates)).
