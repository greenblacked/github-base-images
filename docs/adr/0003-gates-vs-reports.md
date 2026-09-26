# 0003 — Security gates block only what this repo can fix

**Status:** accepted

## Decision

Three checks gate publishing: **fixable HIGH/CRITICAL OS-package vulnerabilities**
(`ignore-unfixed`, `vuln-type: os`), **secrets at any severity** (in images, and in the
working tree via `security.yml`), and **mirror integrity** — the `mirror` job fails the run if an
upstream tag cannot be resolved to a digest, or if the mirrored copy does not resolve back to that
same digest (see [0001](0001-mirror-upstream-bases.md), "Digest control"). Everything else —
library vulnerabilities, Dockerfile misconfiguration, license findings, the zizmor workflow audit,
the git-history secret scan, the OSV scan of the SBOM — is **reported**: printed to logs, kept as
90-day artifacts, and uploaded to code scanning, but never red.

Two further gates sit either side of publishing rather than in front of it:

- **Post-sign verification** — straight after `cosign sign`, the merge job re-derives from the
  registry that the signature verifies under the exact expected identity and that the index carries
  both SBOM and provenance attestations (`check-published.sh --ref`), and then that the GitHub
  build provenance attestation verifies with `gh attestation verify`. A failure, or a check that
  could not run, fails the run.
- **Dependency review** — on pull requests, a change that adds a dependency (in practice an action
  version) with a known HIGH or CRITICAL advisory fails the PR's checks.

## Why

A gate is only honest if going red always means an action *this repo* can take:

- A fixable Debian CVE is actionable — `apt` pulls the patched package on the next rebuild.
  An **unfixed** CVE is not, which is what `ignore-unfixed` encodes.
- Library findings are the runtime's own bundled dependencies inside the upstream image; gating
  on them blocks every publish on someone else's release schedule.
- A committed credential is always fixable here, so it always gates — except in **git history**,
  where the only real fix is a rewrite plus rotation; failing every unrelated build until that
  happens would punish the wrong thing. History hits are incidents, not broken builds.
- Misconfiguration and workflow-audit findings are best-practice pressure, applied through the
  Security tab where they can be triaged, not through a red X that trains people to click re-run.
- **Mirror integrity is the odd one out here, honestly.** Its remedy is exactly the re-run this
  section just argued against gating on. It gates anyway, and the reasoning is different from the
  other two: a digest mismatch is not a static finding with a known fix — it is this run's
  evidence that the bytes just copied are not the bytes that were resolved, which is worse than no
  mirror at all, because every image downstream would build on it silently. Re-running is the
  correct response precisely because the fault this gate exists to catch is non-deterministic —
  the resolve/copy race the mirror-digest-integrity work closed for the common path — so most
  mismatches are expected to be transient and expected to clear on a second attempt. What makes
  this an honest gate rather than the "click re-run" anti-pattern above is what happens when it
  does *not* clear: a mismatch that survives a re-run is not something to keep retrying past, it
  is the trigger for a human to look at the registry, which is an action this repo can take even
  though "re-run" alone is not one.
- **Post-sign verification gates because every way it can fail is this repo's own doing.** A
  signature that does not verify as `build-image.yml@refs/heads/main`, an index missing its
  attestations, a GitHub attestation that `gh` cannot verify — each is a regression in this
  pipeline (a renamed workflow, a changed buildx flag, a permission dropped from the caller), and
  each was previously only discovered by the scheduled audit, days later and detached from the
  commit that caused it. It cannot un-publish — the tags have moved by the time a signature exists
  to check — so what it buys is attribution: the run that broke it is the run that goes red. It
  reuses `check-published.sh` rather than restating its checks, because that script's identity
  regexp and its "absent" vs "could not check" split were each fixed against real cosign, buildx
  and GHCR behaviour, and a second copy is where those fixes would silently fail to arrive. Both
  outcomes fail the job, with different messages: *absent* and *could not check* are different
  diagnoses, but neither is a pass.
- **Dependency review gates because the remedy is not merging.** It reports on what a pull request
  *adds*, against an advisory naming the exact version — so red always has an action: pick a
  different version, or leave the PR open. `fail-on-severity: high` matches the image gate's
  threshold. If the review itself cannot run (dependency graph off, API unreachable), the action
  fails rather than passing, which is the right direction for a gate.
- **The OSV scan reports, for the same reason library findings do** — it sees the same packages as
  Trivy through a second database, and a second opinion on something already not gated cannot
  become the gate. It still fails **loudly when it cannot look**: osv-scanner exits 1 for
  findings and 127–130 when it could not scan (unreachable database, no packages read, bad
  config); only the first is success. That matters here more than usual, because the tool's own
  failure mode is a well-formed SARIF with zero results — exactly an empty report posing as a
  clean scan — so the wrapper deletes the SARIF whenever the scan did not complete. It runs as its
  own job after `build`, not inside it: an OSV outage turns the run red, but neither publishing
  nor the `digests.json` aggregate is blocked by it (`digests` runs on `!cancelled()` and
  aggregates every manifest that was published).

  What reaches code scanning is filtered the same way as the Trivy SARIF: `security-severity`
  >= 7.0. Findings whose rule has no score at all are uploaded too — an unscored finding is not a
  low one, and dropping it would be exactly the silent narrowing this section argues against. The
  unfiltered SARIF is the 90-day artifact, and the job summary counts kept, dropped and unscored.

  One more reason it is only a report: as produced, Trivy's SBOM matches nothing in OSV's Debian
  data — the purl carries the point release (`debian-12.15`, where OSV files under `Debian:12`)
  and names binary packages (`libc6`) where OSV keys by source (`glibc`). The scan normalises a
  copy of the SBOM first (see `scripts/osv-scan-sbom.sh`); on `debian:bookworm-slim` that took it
  from 0 findings to 98. A mapping this repo maintains is a mapping that can drift, which is a
  reason to watch its output, not to gate on it — and a reason for the one tripwire it does have:
  if none of an SBOM's Debian packages carries Trivy's source-name property any more, the scan
  fails rather than falling back to binary names.

## Consequences

- A green publish means: built, smoke-tested, both platforms asserted present, no fixable
  HIGH/CRITICAL OS vulns, no secrets, and every base mirrored by verified digest — and nothing
  more. SECURITY.md spells out the same scope for reporters.
- The weekly rebuild is what turns "fixable" into "fixed"; the gate is what guarantees the
  rebuild picked the fix up.
- A mirror-verify failure blocks the `image` job entirely (it depends on `mirror`), so a bad
  mirror never reaches a build the way an unfixed library finding is allowed to.
- A green publish run additionally means the published index verified — cosign identity, both
  buildx attestations, and the GitHub attestation — against the registry, in that run. The
  scheduled audit still exists for everything that can change *after* a run.
- *Security → Code scanning* gains an `osv-<image>-<arch>` category per image and architecture,
  HIGH/CRITICAL plus unscored. `osv-scanner scan` v2.6.0 has no severity flag, so the filter is
  applied to its SARIF afterwards, with `rules[]` left intact. On `debian:bookworm-slim` that is
  42 of 98 findings uploaded (36 scored >= 7.0, 6 unscored), 56 kept only in the artifact.
- A run where some image failed is red, but `digests.json` still covers every image that
  published and verified, and says how many of the planned images that is.

## The SARIF report is not the gate with the pipes swapped

For a while the vulnerability SARIF step (uploaded to the Security tab) carried the same flags as
the gate: `ignore-unfixed`, `severity: HIGH,CRITICAL`, `vuln-type: os`. The intent was "the same
scope, just as a browsable report instead of an exit code." That reasoning was wrong on both what
it would contain and what it actually did contain.

**What it would contain, if the flags worked as written:** a SARIF step whose scope is identical
to the gate's can only ever report exactly what the gate is simultaneously failing on. On any
build that reaches the SARIF step at all, the gate has already passed with zero matching findings
— so the report is, by construction, empty every time it runs. That is not a report; it is the
gate's exit code rendered a second, more expensive way.

**What it actually contained, because of a flag that was never set:** trivy-action's SARIF
handling silently discards `severity:` unless `limit-severities-for-sarif: true` is also passed —
that input has no default, and the step didn't set it. From the action's `entrypoint.sh`:

```sh
# Handle SARIF
if [ "${TRIVY_FORMAT:-}" = "sarif" ]; then
  if [ "${INPUT_LIMIT_SEVERITIES_FOR_SARIF:-false,,}" != "true" ]; then
    echo "Building SARIF report with all severities"
    unset TRIVY_SEVERITY
  else
    echo "Building SARIF report"
  fi
fi
```

So the SARIF step's real scope was never "same as the gate." It was: all severities (UNKNOWN
through CRITICAL), OS packages only, fixed-only. The `severity: HIGH,CRITICAL` line was dead
input the whole time. **Any SARIF-format trivy-action step that also passes `severity:` needs
`limit-severities-for-sarif: true` next to it, or the severity filter does nothing** — this is
easy to get wrong because the input is silently accepted either way; nothing errors, nothing
warns, the step just quietly ships more than intended.

What actually made the report near-empty in practice wasn't the (non-functional) severity match
with the gate — it was `ignore-unfixed` on an image whose build had just run `apt-get upgrade`.
"Fixed" means an updated package exists; the build already installed it. What survives that is
overwhelmingly *unfixed* CVEs, which `ignore-unfixed` excludes by definition. The one filter that
was load-bearing for "the Security tab is empty" was never the one intended as the primary filter.

**Decision:** the SARIF step now diverges from the gate on purpose, to carry the accepted risk the
gate deliberately tolerates rather than duplicate its exit code:

- Drops `ignore-unfixed` — unfixed HIGH/CRITICAL OS CVEs are the real, accepted risk in these
  images and belong in the Security tab, not only in the full-severity job artifact.
- Drops `vuln-type: os` — library findings (the runtime's own bundled `pip`/`npm`/`gem` packages)
  are included. The gate excludes them for the same reason as always (not fixable from this repo);
  that is the argument *for* reporting them, not for keeping them out of the one view built for
  browsing findings over time.
- Sets `limit-severities-for-sarif: true` alongside `severity: HIGH,CRITICAL`, so the severity
  filter this time actually takes effect. Given the widening above, the alternative (every
  severity) would be a large volume increase across every image/architecture upload category, most
  of it not worth a human's attention. UNKNOWN/LOW/MEDIUM findings still exist — in the JSON and
  table report artifacts, which run with no filters at all — just not in the triaged view.

The gate itself is unchanged: `ignore-unfixed`, `severity: HIGH,CRITICAL`, `vuln-type: os`. Nothing
above should ever be read as loosening or widening what blocks a publish — only what gets reported
once a publish already succeeded.

## Revisit if

An image ever vendors third-party libraries directly (library findings would become actionable),
or a gate starts flapping on findings with no available fix — that is the signal the scope
drifted, not that the gate should be muted. For mirror integrity specifically: if mismatches are
ever observed to survive re-runs against a registry nobody believes is compromised — a genuinely
flaky or inconsistent upstream, not an attack — the "re-run clears transient faults" assumption
above has stopped holding and the gate needs a different remedy, not a quieter one.

For the OSV report: if OSV's Debian ecosystem or Trivy's purls change shape (a point release OSV
does recognise, source names in the purl), the normalisation in `scripts/osv-scan-sbom.sh` should
shrink rather than grow. The symptom to look for is a sharp drop in a Debian image's findings,
not necessarily to zero: the distro fix alone left bookworm-slim at 27 of 98, and a partial loss
of Trivy's source-package properties would land somewhere in between — the input counts in the
job summary (mapped by source name vs by binary name) are where that shows first.
