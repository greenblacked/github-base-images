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
builds. The job summary lists them, carries the gate's own table, and has one line of the full
vulnerability report's counts per severity, split into fixable and unfixed (fixable: Trivy lists a
fixed version), computed from its JSON with `jq`. The full tables are too large for it (a step
summary is capped at 1 MiB):

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
    be read (after three retries) or scanned, it runs **strict**: every finding blocks, and the
    summary says why. The published image is read with the job's own token on every run, pull
    requests included, so private packages are compared too. An unreadable report fails the
    gate. It is never read as "no findings".
  - It also scans the **base image the build is FROM**, for the same architecture and with the
    same flags: the mirror on `main`, the upstream ref from `images.json` elsewhere (so
    `debian:trixie-slim` for `ci-tools`, `ci-cloud`, `ci-security` and `ci-db`, the .NET SDK
    image for the `ci-dotnet*` images, and so on). A finding the published image lacks but the
    base image carries is **inherited from the base image**: listed, never blocking. So what blocks
    is the candidate minus the published image minus the base image. This repository cannot fix
    what a base image ships (the .NET SDK's bundled MSBuild and cryptography packages, the python
    image's own pip); blocking on it would only withhold the fixes the rebuild carries, and the
    base's fixes arrive through the daily rebuild anyway. It applies to strict runs too, so a new
    image is blocked only for what it adds on top of its base. The base-image baseline is
    best-effort: when the base cannot be read or scanned the gate runs without it, as before, and
    says so in a notice.
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
    to all three scans, and are printed in the gate step's log and summary. The reports above never
    use them; the code-scanning upload does ([The Security tab](#the-security-tab)). See
    [Vulnerability exceptions](#vulnerability-exceptions).
  - All three scans and the decision are kept as the `vuln-gate-<image>-<arch>` artifact.
- **Secret scan** — **gates at any severity**. A baked-in credential in a public CI image is
  always fixable from this repo, with no upstream to wait on, so there is no excuse for shipping
  one. It is Trivy's secret scanner with its built-in detection rules and **without its built-in
  allow rules**: [.github/trivy-secret.yaml](../.github/trivy-secret.yaml) disables every one of
  them by ID (`disable-allow-rules`). Those rules
  ([builtin-allow-rules.go](https://github.com/aquasecurity/trivy/blob/v0.70.0/pkg/fanal/secret/builtin-allow-rules.go))
  used to skip, unread, every file whose path contained `test` or `example`; every `vendor/`,
  `locale/` and `locales/` directory; `*.md` and Python `.dist-info/` metadata; and everything under
  `usr/share/`, `usr/include/`, `usr/lib/`, `usr/local/lib/pythonX.Y/` (every pip
  `site-packages`), `usr/local/go/`, `opt/yarn-v*/`, `usr/src/wordpress/` and `var/log/anaconda/`.
  The gate now reads all of those.
  - **What it still does not read.** Trivy skips some files in code rather than by an allow rule,
    and no configuration reaches that: anything under a `node_modules` or `.git` directory; the
    lock files `go.mod`, `go.sum`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`,
    `Pipfile.lock` and `Gemfile.lock`; the extensions `.jpg .png .gif .doc .pdf .bin .svg .socket
    .deb .rpm .zip .gz .gzip .tar`; binary files other than Python `.pyc`; and files under 10
    bytes. So the gate means *no secret Trivy can detect in any file it reads*, and those are the
    files it does not.
  - **What it excuses.** Upstream software ships published test and documentation fixtures —
    test-server keys, fake service-account files, sample tokens — and with the allow rules off the
    gate sees them. Each one is reviewed and excused explicitly, never by a path pattern:
    - [.github/trivy-secret-ignore.yaml](../.github/trivy-secret-ignore.yaml) excuses a file
      fixture for **one Trivy rule ID at one exact path** (a `*` only for a version-numbered path
      segment), with a statement of what it is. Another rule firing on the same file, or the same
      rule on another file, still fails. Today: the Go standard library's test keys (`ci-go`), the
      test suites gsutil vendors in the Google Cloud CLI and PyJWT's README token in the Azure CLI
      (`ci-cloud`), and the AWS CLI's sample key-pair output (`ci-tools`).
    - One content allow rule in `.github/trivy-secret.yaml` excuses AWS's documentation
      placeholder key IDs (`AKIAIOSFODNN7EXAMPLE` and five more, each named in full), which the AWS
      CLI's help examples use about fifty times.

    The secret *report* uses the configuration but not the exceptions, so every excused match is
    still listed in the `security-report-<image>-<arch>` artifact. Where nothing in a CI image
    could need a fixture, removing it in the Dockerfile is preferred to excusing it: `ci-cloud`
    deletes the two test-server keys in gsutil's vendored urllib3 (`…/urllib3/dummyserver/`).
  - **Tied to the Trivy release.** The allow-rule IDs are those of the Trivy version the pinned
    trivy-action installs (0.70.0), recorded in the file's `# trivy-version:` line. A new release can
    add an allow rule, which would quietly stop the gate reading its paths, so the gate fails when
    the Trivy it runs is any other version, until the list is re-checked; it also fails if the
    file is missing, which Trivy would otherwise read as "no configuration" without a word.
    `scripts/lint.sh` checks that the list is exactly the release's IDs, that every Trivy secret
    scan in the workflows uses the file, and that every exception has the form above.
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

**Code scanning shows what someone can act on, and nothing else.** Per image and architecture, a
second Trivy scan is emitted as SARIF and uploaded under the `<image>-<arch>` category with the
gate's own filters: HIGH/CRITICAL (`limit-severities-for-sarif: true` alongside `severity:`, or
trivy-action silently ships every severity), **`ignore-unfixed`**, OS packages and libraries, and
the gate's exception file. So every alert names a fixed version, and none is one an active
[exception](#vulnerability-exceptions) excuses. The upload is `continue-on-error`: code scanning
must never be the reason an image fails to publish.

What is open there is therefore a short list: fixable findings the published image already carries
(*known upstream* — usually a package vendored inside another, waiting on an upstream release; see
the gate above), plus anything in the window between a fix appearing and the next daily rebuild.
Each closes on its own when the rebuild or an automated update installs the fix: the next upload
of that category no longer contains it, and code scanning marks it fixed.

**The unfixed inventory is not on that page.** HIGH/CRITICAL findings with no fixed version
anywhere — unfixed Debian CVEs, the runtime's own bundled `npm`, `pip` and `gem` packages — are
accepted risk that nobody here or downstream can act on. Until 2026-10-14 they were uploaded too,
as a standing record, and came to about 6,400 open alerts against a few dozen actionable ones
([ADR 0003, amendment of 2026-10-14](adr/0003-gates-vs-reports.md#amendment-2026-10-14-code-scanning-shows-only-actionable-findings)).
They are kept, per build and for 90 days, in:

- the `security-report-<image>-<arch>` artifact: `trivy-<image>-<arch>.json` and `.txt` (every
  severity, fixed and unfixed, no exceptions applied), `trivy-<image>-<arch>.sarif` (every
  HIGH/CRITICAL finding, fixed or not — the inventory as it used to be uploaded), and the SBOM;
- the `osv-report-<image>-<arch>` artifact: osv-scanner's findings, every severity;
- the build job's log, which prints the full vulnerability table.

The narrowing closed the old alerts by itself: the upload kept its category, and code scanning
treats each upload as the complete current state of its category, so the first upload after the
change marked every alert it no longer contained as fixed. No alert was dismissed by hand.

### A second opinion from OSV

After both architectures build, a separate `osv` job runs
[osv-scanner](https://github.com/google/osv-scanner) over the CycloneDX SBOM the build already
produced — no second image scan. OSV aggregates the Debian and Ubuntu security trackers alongside
the npm, PyPI, RubyGems and Go advisories, so it is a different database looking at the same
packages. **Reported, not gating.** The report, every severity, is the
`osv-report-<image>-<arch>` artifact; the job summary counts its findings by score.

**Its findings are not uploaded to code scanning** (since 2026-10-14). Code scanning shows only
fixable findings, and osv-scanner's SARIF cannot say whether a finding has a fix for *this*
image's release: it carries no fixed version on a result, only a Markdown table in the rule's help
built from every ecosystem the advisory covers, so a CVE fixed in Debian 11 but not 12 reads as
fixed on a bookworm image. Trivy's upload already carries the fixable findings for the same
packages. The job still uploads to its `osv-<image>-<arch>` category — an **empty** run, on every
build — because an upload is what closes a category's open alerts: the first one closed the
thousands of OSV alerts uploaded before, and the rest keep the category at zero.

Three things about it are less obvious than they look:

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
```bash
./scripts/osv-scan-sbom.sh sbom-ci-tools-amd64.cdx.json full.sarif upload.sarif   # locally
```

## Vulnerability exceptions

`.github/vuln-exceptions.json` is the only way past the vulnerability gate, and it is narrow on
purpose ([ADR 0006](adr/0006-gate-on-fixable-library-vulnerabilities.md#exceptions-expiring-per-image-per-id)).
Since [ADR 0008](adr/0008-self-updating.md) an entry is needed only for a finding a build *adds*
(one the published image already carries is known upstream, and one the base image carries is
inherited; neither blocks). It is for a
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
- `purls` is the package's PURL as Trivy prints it in the JSON report's `PkgIdentifier`,
  `pkg:<type>/<name>@<version>`, for example `["pkg:pypi/msgpack@1.1.2"]`. It pins the exact
  installed version, so the entry stops applying when the package changes.
- An entry with `purls` needs `paths` as well. A PURL alone matches that package and version
  anywhere in the image, so an entry written for a copy vendored inside an upstream release would
  also excuse a fixable copy of the same package added somewhere else; with `paths` too, Trivy
  matches only the copy the entry was written for.
- `no_path` is the one way to keep `purls` without `paths`: a sentence on why Trivy reports the
  finding with no path to narrow to. Today that is only pip's vendored packages, which Trivy reads
  from `pip/_vendor/bom.cdx.json` with no package path, under the aggregate `Python` target that
  every site-packages package in the image shares too. Check it in the JSON report: the finding
  has no `PkgPath`, and its `Target` is `Python`. `no_path` is read by lint and by
  `build-image.yml`'s checks, and never written into the Trivy ignore file.

### Adding and renewing

**Adding one.** Take the ids from the failing gate step's table — all of them, both
architectures — and check that no release of the thing that bundles them carries the fix yet.
Add one entry per image and id, then run `./scripts/lint.sh`, which checks every field, rejects
an unknown image, a malformed id, date, path or PURL, an entry with neither `paths` nor `purls`,
`purls` with neither `paths` nor `no_path`, a duplicate, or an expiry more than 90 days out. A change to the file rebuilds exactly the images
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
  ghcr.io/greenblacked/ci-tools:trixie-v1
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
  ghcr.io/greenblacked/ci-tools:trixie-v1 2>&1 | head
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

Both checks retry before they fail ([`scripts/verify-ref.sh`](../scripts/verify-ref.sh)). They read
the signature and attestations back from the registry seconds after they were written, and that
read is not reliably consistent yet: one publish saw the signature missing four seconds after
`cosign sign` on a single image, while the other twenty passed and a re-run of the same job passed.
So a failed or inconclusive check is repeated, up to four attempts, 10, 20 and 40 seconds apart,
with every failed attempt logged as a warning. Only the last attempt decides, and its failure fails
the run as before, saying how many attempts were made; a usage or unexpected error is not retried.

Last, the merge job checks the published digest can be pulled with no credentials
([`scripts/check-public.sh`](../scripts/check-public.sh), same retry), so a package that is not
public fails the run ([Visibility and authentication](images.md#visibility-and-authentication)).

### Or with the GitHub CLI

Each published index also carries a **GitHub build provenance attestation**, generated by
[`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance) in the
same job that runs cosign. It is independent of the cosign signature — a second verification
path, not a replacement:

```bash
gh attestation verify oci://ghcr.io/greenblacked/ci-tools:trixie-v1 \
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
docker buildx imagetools inspect ghcr.io/greenblacked/ci-ruby34:trixie-v1
```

`sbom: true` and `provenance: mode=max` are set on the push step only — the test build uses the
docker exporter via `load:`, which cannot carry attestations. `imagetools create` preserves them
into the final multi-arch index.

### The published image is the tested image

That makes the push a second build. It publishes the image the smoke tests and both gates judged,
not a rebuild of it, and that is checked rather than assumed:

- **Same inputs.** Both builds run on the job's one buildx builder with the same context,
  Dockerfile, platform and build args — including the same `BASE_IMAGE`, which is the base's
  per-arch digest, resolved once before either build (the *Base image baseline* step), not a tag
  each build resolves for itself. No build arg or label carries a date, and `SOURCE_DATE_EPOCH`
  is not set. So every step of the push is a cache hit on the builder's own cache, and the push
  re-exports the test build's layers. The attestations are a separate manifest beside the image
  (`unknown/unknown`) and leave the image's manifest and config alone.
- **Checked.** [scripts/verify-published-layers.sh](../scripts/verify-published-layers.sh) runs
  between the push and *Export digest*. It reads the pushed index, takes its one image manifest
  (ignoring the attestation manifest), and compares that image's config with the tested
  `<image>:test` in the daemon: `rootfs.diff_ids` (every layer, uncompressed, in order), platform,
  and `Env`, `Entrypoint`, `Cmd`, `User`, `WorkingDir` and `Labels`. Any difference — a cache miss
  that re-ran a step, a moved base — or a registry it cannot read fails the job, so that
  architecture's digest is never exported and the merge job assembles, signs and attests
  nothing. Only the per-arch `<version>-<arch>` tag the push wrote is left behind; nothing
  consumes it.

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

- **Repository secret scan** — Trivy over the working tree, covering workflows, scripts, and the
  Makefile, none of which the image scan can see (nothing is `COPY`ed in). **Gates**, on the same
  reasoning as the image secret gate — and with the same `.github/trivy-secret.yaml` (see *Secret
  scan* above), so it reads Markdown (`*.md`, most of the docs) and every path containing `test`
  or `example` (the `scripts/test-*.sh` suites among them) too. It takes none of the image gate's
  fixture exceptions, which name paths inside the images: this tree has nothing to excuse, so any
  finding fails. The git history scan below uses gitleaks's own default allowlist.
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
  cannot see (a pinned, checksum-verified release binary, its pins in `.github/tool-pins.env`). A credential committed and removed in a later commit is still fetchable by anyone
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
  What reaches code scanning leaves out the findings accepted by design
  ([below](#repository-level-alerts-accepted-by-design)); the artifact keeps them.

Four of these publish SARIF to the Security tab — everything above except the git-history scan,
whose findings are deliberately kept out of a view people triage to empty, and dependency review,
whose verdict is the PR check itself. So *Security → Code scanning* collects repository secrets
(`repo-secrets`), workflow findings (`workflow-audit`, zizmor), the CodeQL results
(`codeql-actions`) and the Scorecard result (`scorecard`). Image vulnerabilities are uploaded
there too, under their own `<image>-<arch>` categories — fixable HIGH/CRITICAL findings only — and
`osv-<image>-<arch>`, which is always empty; see [The Security tab](#the-security-tab) and
[OSV](#a-second-opinion-from-osv) above.

> **First run:** the Scorecard badge stays grey until the workflow has run once on `main` and
> published its results. Both badges track `main`, so they will not reflect a pull request.

### Repository-level alerts accepted by design

The repository-level categories follow the same rule as the image ones: code scanning shows what
someone can act on ([ADR 0003, amendment of 2026-10-14](adr/0003-gates-vs-reports.md#amendment-2026-10-14-code-scanning-shows-only-actionable-findings)).
A few findings there are true and permanent, because they describe how this repository is built
on purpose. They are accepted in one reviewed place per tool, each with its reason, and every
other finding — a new one of the same kind included — still shows.

**zizmor (`workflow-audit`).** `self-repository` on the two local reusable-workflow calls in
`build-and-push.yml` (`uses: ./.github/workflows/build-image.yml` and `alerts-report.yml`):
calling a workflow from this repository at this commit is the design of
[ADR 0002](adr/0002-images-json-reusable-workflow.md). Each is suppressed on its own line with
`# zizmor: ignore[self-repository]` and a comment, like the other inline ignores, so any other
`uses:` is still audited.

**Scorecard (`scorecard`).** The `scorecard-upload` job in `security.yml` runs
[`scripts/filter-scorecard-sarif.sh`](../scripts/filter-scorecard-sarif.sh) over Scorecard's SARIF
before uploading it, driven by
[`.github/scorecard-accepted.json`](../.github/scorecard-accepted.json):

| Rule | Accepted where | Why |
|---|---|---|
| `PinnedDependenciesID` | the `FROM ${BASE_IMAGE}` line of every `ci-*/Dockerfile.ci` | the base is a tag by design — the verified mirror on `main`, upstream on pull requests, rebuilt daily ([0001](adr/0001-mirror-upstream-bases.md), [0007](adr/0007-automatic-updates.md), [0008](adr/0008-self-updating.md)) |
| `PinnedDependenciesID` | the `npm install --global "npm@${NPM_VERSION}"` line of every `ci-node*` | pinned by exact version, moved by the pin-bump bot; npm cannot take a hash |
| `CodeReviewID` | rule-wide | one maintainer; automated PRs merge after the required checks ([0008](adr/0008-self-updating.md)) |
| `FuzzingID` | rule-wide | Dockerfiles and shell: nothing to fuzz |
| `CIIBestPracticesID` | rule-wide | the OpenSSF Best Practices badge is optional |

An entry is either rule-wide (`rule`, `reason`) or tied to a line: `path`, an anchored regular
expression for the file, and `match`, an anchored one for the whole Dockerfile instruction that
starts on the flagged line. For a line entry the script reads that instruction from the
checked-out commit (Scorecard names its first line, `region.startLine`; continuation lines are
joined the way Docker joins them, and whitespace is collapsed) and drops the result only if all of
it matches. So a new `RUN pip install foo` beside an accepted `FROM` line is still reported, and so
is a package added on a continuation line of an accepted multi-line `RUN`. A result it cannot place (no location, a path outside the checkout, a line past the
end) is kept unless a rule-wide entry covers its rule. Every entry needs a `reason`, and an unknown
key fails, so a typo cannot widen an entry. The job log lists every dropped result (rule,
`path:line`, reason), every kept one, and any entry that matched nothing.

It fails closed: the filtered file is written only on success, and when the script fails the job
warns and uploads the **unfiltered** SARIF, so a broken filter shows everything rather than hiding
anything. The `scorecard-results` artifact is always the unfiltered result. The categories are
Scorecard's own (`supply-chain/local`, `supply-chain/online-scm`, `supply-chain/branchprotection`,
from the SARIF's `automationDetails`, which the filter keeps), so the accepted alerts close on the
first filtered upload, with no dismissal by hand. `scripts/lint.sh` validates the list and runs it against the tree, so a
Dockerfile whose `FROM ${BASE_IMAGE}` stops being covered fails lint rather than reappearing in
the Security tab. The filter is a separate job because Scorecard, when publishing results, only
accepts a job made of its approved actions — no `run:` steps.

- **`BranchProtectionID`** is accepted while `main` is actually protected. The `main` ruleset is
  active: no deletion, no force push, pull requests required (0 approvals), the
  [required checks](#required-checks) below, and repository admins as the only bypass.
  Scorecard's top tiers also want two or more approving reviewers and code-owner review, which a
  single-maintainer repository cannot have, so the check never reaches 10. The `scorecard-upload`
  job reads the rules GitHub applies to `main` on every run, and drops this entry (so the alert
  shows again) whenever they stop including any of deletion and force-push protection, pull requests and required status checks.

One Scorecard alert is **not** accepted, and stays visible on purpose:

- **`MaintainedID`** fires because Scorecard counts a repository younger than 90 days as
  unmaintained. This one was created on 2026-07-20, so it clears on its own from about
  2026-10-18.

Changing the list is a reviewed pull request like any other; delete an entry once its finding is
gone (the log's "matched no result" note says when).

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

*Security → Code scanning* spreads its alerts over forty-odd categories — every image,
architecture and tool — and the list says how many and little else.
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
- **not-actionable** image alerts (unfixed, below HIGH, or OSV) still open from before code
  scanning was narrowed, by category. Each category's next upload closes them, so one still listed
  days later means that image has stopped uploading (its build is failing);
- **stale** categories: alerts uploaded for images that no longer exist (`ci-go125`, `ci-rust185`,
  …). Nothing will upload there again, so they never close on their own; delete the category under
  *Security → Code scanning → Tool status*.

It runs after every publish run on `main` (the `alerts` job in `build-and-push.yml`), daily, and
on demand via *Run workflow*. Read it on the run's summary page; the full
`report.md`, with the raw `code-scanning.json` and `dependabot.json` it was built from, is the
`code-scanning-report` artifact (90 days). A very large report is cut in the summary, section by
section, never in the artifact.

**The job log has the short version**, readable without downloading anything: one line per
fixable HIGH/CRITICAL alert no exception covers (image, architecture, CVE, severity, package,
installed → fixed version, alert number), per fixable HIGH/CRITICAL Dependabot alert, and per
repository-level alert (tool, rule, `path:line`, severity, category), then one line per category
of not-actionable leftovers. It is capped at 200 lines; `report.md` has the rest.

**Open fixable alerts are a warning, not a failure.** A fixable HIGH/CRITICAL Trivy alert in a
current image is usually *known upstream*: inherited from a runtime image or a vendored package,
with no release that fixes it yet. It ships until one does
([ADR 0008](adr/0008-self-updating.md)). Failing on it would keep `main` red for weeks over
something nothing here can change. So the run shows a warning with the count, and every such alert
is listed in the report. A HIGH/CRITICAL Dependabot alert with a patched version is treated the
same way; Dependabot's own pull request for it merges itself once green. Not-actionable leftovers,
stale categories and alerts covered by an active exception (listed and counted separately) are not
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
Both Trivy scans run with Trivy's built-in allow rules disabled, so they read test, example,
vendored and system-library paths too; what Trivy still skips in code (`node_modules`, `.git`,
lock files, archives, binaries) is listed under
[Tests and security scanning](#tests-and-security-scanning) (*Secret scan*).

The Dependabot fetch needs the `vulnerability-alerts: read` token permission, which is separate
from `security-events`. The pinned actionlint predates that permission, so
`.github/actionlint.yaml` ignores that one message, in those two workflow files only.

## Supply-chain pins

Every action is pinned by commit SHA ([ADR 0004](adr/0004-sha-pinned-actions.md)), and every
downloaded binary — the tools in the images and each lint engine — is checksum-verified. Wherever
the vendor publishes a checksum, that is the one. The two that publish none (the AWS CLI and
gcloud) carry a trust-on-first-use sha256 that `scripts/bump-pins.sh` records from its own
download, after verifying AWS's signature for the AWS CLI; they are labelled as such, and listed
in [CONTRIBUTING.md](../CONTRIBUTING.md#what-does-not-belong-in-an-image). The Docker CLI was the
third until it moved from Docker's unsigned static tarball to Docker's signed apt repository: it
is now `docker-ce-cli` at an exact version, installed by apt, which checks every byte against
Docker's signature (below).
Composer's sha256 is also hashed from the bump's own download of the phar on the GitHub release,
but it is not trust on first use: it is pinned only once GitHub's attestation for exactly that
digest, and the phar's GPG signature, verify (below).

The pins live in the Dockerfiles, in `scripts/lint.sh` (the lint engines), in the pip
requirements files, and, for the two binaries a workflow step downloads itself (gitleaks for the
git history scan in `security.yml`, osv-scanner in `build-image.yml`), in
[.github/tool-pins.env](../.github/tool-pins.env). None is in a workflow file: the pin-bump bot
pushes with `GITHUB_TOKEN`, which GitHub refuses for any change under `.github/workflows/`, and
`bump-pins.sh --check` (run by lint) fails a pin there. `tool-pins.env` is data, never sourced:
each step takes exactly one `KEY=value` line per key, the value a dotted version or a 64-hex
sha256, and fails before downloading anything otherwise
([ADR 0008](adr/0008-self-updating.md#amendment-2026-10-19-no-bump-managed-pin-lives-in-a-workflow-file)).

A checksums file taken from the same release as the artifact only proves the two were published
together, so wherever the vendor signs it, `bump-pins.sh` verifies that signature before it reads
a single checksum. Where the vendor signs the artifacts instead, every digest the bump would pin is
verified on its own — against the vendor's SLSA provenance, its GitHub artifact attestation, or
the binary's own signature — before any is written. A missing, bad or wrong-identity signature or
attestation, for any one digest, fails the bump (an error row: nothing is edited, no pull request
is opened). The identities and keys are pinned in its `SIGS` table; each was read from a real
release, and those marked below were verified end to end, before it was pinned:

| Tool | What is signed | Verified with | Pinned identity or key |
|---|---|---|---|
| terraform | `terraform_<v>_SHA256SUMS` (`.sig`) | `gpgv` | HashiCorp's key, `scripts/keys/hashicorp.asc` (from `hashicorp.com/.well-known/pgp-key.txt`), primary fingerprint `C874011F0AB405110D02105534365D9472D7468F` |
| AWS CLI | each installer zip (`.sig`) | `gpgv` | AWS's key, `scripts/keys/aws-cli.asc` (from the Linux section of AWS's [install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)), fingerprint `FB5DB77FD5C118B80511ADA8A6310ACC4672475C` |
| trivy | `trivy_<v>_checksums.txt` (`.sigstore.json`) | `cosign verify-blob` | `https://github.com/aquasecurity/trivy/.github/workflows/reusable-release.yaml@refs/tags/v<v>`, issuer `https://token.actions.githubusercontent.com` |
| syft | `syft_<v>_checksums.txt` (`.sigstore.json`) | `cosign verify-blob` | `https://github.com/anchore/syft/.github/workflows/release.yaml@refs/heads/main`, issuer `https://token.actions.githubusercontent.com` (anchore releases from `main`) |
| grype | `grype_<v>_checksums.txt` (`.sigstore.json`) | `cosign verify-blob` | `https://github.com/anchore/grype/.github/workflows/release.yaml@refs/heads/main`, issuer `https://token.actions.githubusercontent.com` |
| cosign | `cosign_checksums.txt` (`.sigstore.json`) | `cosign verify-blob` | `keyless@projectsigstore.iam.gserviceaccount.com`, issuer `https://accounts.google.com` |
| osv-scanner | each pinned digest, as a subject of the release's SLSA v0.2 provenance (`multiple.intoto.jsonl`) | `cosign verify-blob-attestation --type slsaprovenance --digest` | `https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@refs/tags/v2.1.0`, issuer `https://token.actions.githubusercontent.com`, **and** workflow repository `google/osv-scanner`, ref `refs/tags/v<v>`, trigger `push` |
| hadolint | each `checksums.sha256` digest, by its GitHub artifact attestation (SLSA v1) | `cosign verify-blob-attestation --type slsaprovenance1 --digest` | `https://github.com/hadolint/hadolint/.github/workflows/release.yml@refs/heads/master` (hadolint releases from `master`), repository `hadolint/hadolint` |
| actionlint | each archive digest in `actionlint_<v>_checksums.txt`, by its GitHub attestation | as hadolint | `https://github.com/rhysd/actionlint/.github/workflows/release.yaml@refs/tags/v<v>`, repository `rhysd/actionlint` |
| Composer | `composer.phar` on the GitHub release: its digest by GitHub attestation, and the file by its `.asc` | as hadolint, then `gpgv` | `https://github.com/composer/composer/.github/workflows/release.yml@refs/tags/<v>` (no `v`), repository `composer/composer`; key `scripts/keys/composer.asc` (from keyserver.ubuntu.com: Composer publishes no official copy, so it is not refreshed), fingerprint `161DFBE342889F01DDAC4E61CBB3D576F2A0946F` |
| kubectl | each binary (`kubectl.sig`, `kubectl.cert`) | `cosign verify-blob --signature --certificate`, then sha256 of the binary = the `.sha256` sum | `krel-staging@k8s-releng-prod.iam.gserviceaccount.com`, issuer `https://accounts.google.com` |
| Docker CLI | the trixie `InRelease` of `download.docker.com/linux/debian` (clearsigned), then each `stable/binary-<arch>/Packages` by the SHA-256 that signed file lists | `gpgv`, then sha256 of each Packages file = the signed sum | Docker's "Docker Release (CE deb)" key, `scripts/keys/docker.asc` (from `download.docker.com/linux/debian/gpg`), primary fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` (it signs with subkey `D3306A018370199E527AE7997EA0A9C3F273FCD8`) |

The identities are exact, not patterns, and `bump-pins.sh --check` (run by lint) refuses a
pattern, an unknown issuer, a digest row without the repository it binds (and, for the SLSA
generator, the ref), and a signed tool with any file it reads that has no signature row. The
cosign that verifies is the one `sigstore/cosign-installer` installs in the pin-bump workflow —
the same action, pinned by the same SHA, that signs the images — never the cosign release being
bumped.

How the newer rows work, and what each binds:

- **GPG keys, and how they are kept current.** A committed key file never learns of a renewal or
  a revocation by itself, so `bump-pins.sh` refreshes each key from its vendor's official copy
  (its `KEYS` table: HashiCorp's `.well-known/pgp-key.txt`, Docker's `linux/debian/gpg`, and the
  armored block on AWS's install guide, a web page whose tags are stripped and entities decoded,
  and which must hold exactly one distinct key block) every time it uses the key, before it
  verifies anything with it. The fetched copy must be exactly one primary key, the pinned
  fingerprint, and no secret key; it is merged into the committed key in a throwaway
  `GNUPGHOME`, where gpg imports only what that key itself signed, so a renewed expiry, a new
  subkey or a revocation can be added but nothing can be forged or taken away; signatures are
  checked against the merged key. A revocation — of the key, or a new one of a subkey — fails the
  bump. If the vendor cannot be reached, the committed key is used with a warning. A signature by
  an expired key or subkey (`EXPKEYSIG`), or an expired signature (`EXPSIG`), is refused for every
  gpg row, detached or inline, as apt refuses one: a key the vendor has renewed reads as renewed,
  and one that has lapsed with no renewal anywhere fails closed. (HashiCorp's key keeps a signing
  subkey that expired in 2022; its releases are signed by its valid subkey, which `gpgv` reports
  as `VALIDSIG` with no `EXPKEYSIG` — checked against terraform 1.16.6's real `SHA256SUMS.sig` on
  2026-10-19.) When the merged key differs from the committed one, a bump that used it also
  writes it to `scripts/keys` as one of its edits, so its pull request carries the refreshed key
  for review; and the daily pin-bump run opens a *Refresh vendor signing keys* pull request
  (`bump-pins.sh --refresh-keys`, branch `pin-bump/signing-keys`) whenever any key has changed,
  bump or no bump. Nothing builds from `scripts/keys` — the images take Docker's key from
  Docker by fingerprint, and no other key is used at build time — so the committed copies are
  what the bumps start from, and what a reviewer reads. `bump-pins.sh --check` requires a `KEYS`
  row for every gpg key and every file in `scripts/keys` (a URL, or `-` for none), the URL to be
  https, and each committed file still to be exactly one primary key with the pinned fingerprint.
  Composer publishes no official copy of its key (its download page links each phar's `.asc`,
  and `composer.github.io/pubkeys.html` holds the OpenSSL keys for `composer self-update`), so
  `composer.asc` is used as committed, and refreshed by hand.
- **osv-scanner.** The SLSA generator's identity is shared by every repository that uses that
  reusable workflow, so the identity alone would accept anyone's provenance: the source
  repository, the tag and the `push` trigger are what make it Google's release. The generator
  version is part of the identity, so a release built by another one fails the bump, for a person
  to check and update the row. Verified live against v2.6.0's real bundle (with Sigstore's
  trusted root): the pinned digests verify; another repository, ref, generator version or digest
  does not.
- **GitHub attestations (hadolint, actionlint, Composer).** For each digest, `bump-pins.sh` reads
  `GET https://api.github.com/repos/<owner>/<repo>/attestations/sha256:<digest>` (with the
  workflow's `GITHUB_TOKEN` when set; public repositories need no permission for it, so the bump
  job's `contents` permission is enough) and tries each listed bundle — inline, or from its
  `bundle_url`, which GitHub serves snappy-compressed and the script decodes with `python3` — until
  one verifies. An API error, an empty list, or no bundle that verifies fails the bump. Only the
  digests are checked: nothing is downloaded, except Composer's phar, whose hash is what gets
  pinned. hadolint's signer is its workflow on `master`, so its attestation cannot be tied to the
  tag the way actionlint's and Composer's are.
- **kubectl.** The `.sha256` files are unsigned; the binaries carry a detached signature and a
  ten-minute Fulcio certificate (served base64-wrapped; the script unwraps it to PEM). Each binary
  (about 60 MB) is downloaded, verified with cosign, which finds its Rekor entry online (the
  certificate has long expired, so the transparency log's timestamp is what proves it was valid
  when it signed), and its sha256 must then equal the sum read from the `.sha256` file. Rekor and
  Sigstore's TUF root were not reachable from the environment this was written in; the signature
  was checked there against the certificate's key, whose identity and issuer are the pinned ones,
  and the cosign invocation is the one cosign v3 takes for a signature and certificate without a
  bundle (`--insecure-ignore-tlog` is never used).
- **Docker CLI.** The pin is `DOCKER_CLI_VERSION` in `ci-tools/Dockerfile.ci`, the package's full
  version string (`5:29.9.0-1~debian.13~trixie`), and no checksum: apt verifies `InRelease`
  against the keyring the build installs (`signed-by`, the key's fingerprint checked first against
  `DOCKER_KEY_FINGERPRINT`, as Microsoft's is for the Azure CLI), `Packages` against `InRelease`,
  and the `.deb` against `Packages`. The bump walks the same chain before it writes a version:
  the `InRelease` must be one clearsigned message (nothing outside the signed block is read; what
  is read is `gpgv`'s own output of what was signed) by the pinned key, and name the suite;
  each architecture's `Packages` must hash to the sum the signed file lists; and amd64 and arm64
  must carry the same version string. Any failure is an error row. Verified live on 2026-10-18
  against bookworm, and again on 2026-10-19 against trixie, the suite since the
  [Trixie migration](images.md#the-trixie-migration): trixie's `InRelease` gives a good signature
  by the subkey for the pinned primary, and both architectures list `docker-ce-cli` up to
  `5:29.9.1-1~debian.13~trixie`. The unit's version, which `check-pins.sh`
  reports and a bump asks for, is the upstream version and the Debian revision without the epoch
  or the distro suffix (`29.9.1-1`), so a packaging or security fix Docker ships only as a new
  revision is drift too; the bump takes exactly that revision from the signed index, never the
  newest one of an upstream version. The repository publishes no release
  date, so the cooldown is the pin-bump PR's first-seen clock: a Docker bump is `review`, never
  `auto`, though it is verified like a signed checksum. The binary is a different build from the
  static tarball's, at `/usr/bin/docker`; `/usr/local/bin/docker` is a link to it.

Not signature-checked, and why: **gitleaks** and **golang-migrate** publish no signature asset and
have no GitHub attestations (`gh attestation verify` reports none), so they are checked against
their checksums files only. **gcloud**'s tarball has only Google Cloud Storage's md5/crc metadata,
so it stays trust on first use (above). npm, PyPI and RubyGems packages are pinned by their
registries' digests (below).

The
Python packages installed outside an image's base — the Azure CLI's swapped-in libraries
(`ci-cloud/az-overrides.txt`) and zizmor (`.github/zizmor-requirements.txt`) — are exact versions
installed with `pip --require-hashes`, every hash from PyPI. The two third-party apt
repositories are each trusted only through a key whose fingerprint the build checks, and the
image's smoke test checks again: Microsoft's for the Azure CLI
(`BC528686B50D79E339D3721CEB3E94ADBE1229CF`, as Microsoft documents it; `ci-cloud/test.sh`), and
Docker's for the Docker CLI (`9DC858229FC7DD38854AE2D88D81803C0EBFCD88`; `ci-tools/test.sh`). The upstream base itself is copied into GHCR by digest and verified
([Mirrored upstream base](pipeline.md#mirrored-upstream-base)).

Dependabot keeps action pins and base images current with a seven-day `cooldown` on every
ecosystem: nothing is adopted the day it ships, since the window between publication and discovery
is exactly when a same-day bump would pull in a compromised release. The pinned release binaries
Dependabot cannot see are compared against their vendors daily by the pin-drift job, which opens
a tracking issue rather than failing a build. Both are described in full under
[Pin drift](pipeline.md#pin-drift). The pin-bump job then turns that drift into pull requests, with
checksums taken from the vendor's published files where there are any, and the same seven-day
cooldown. The cooldown fails closed: a release whose date cannot be established is not bumped,
and a GitHub release is as old as its most recently uploaded asset. The three tools with no
vendor date wait seven days from the day their PR first carried the version, a date recorded in
the PR and enforced by the merge bot, which no one controlling the vendor's channel can backdate
([Automatic updates](pipeline.md#automatic-updates),
[ADR 0008](adr/0008-self-updating.md#amendment-2026-10-17-the-cooldown-fails-closed-and-has-a-clock-of-its-own)).
Its pull requests and Dependabot's merge themselves once every required check passes, and publish
straight away.
