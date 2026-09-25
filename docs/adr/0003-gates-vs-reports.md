# 0003 — Security gates block only what this repo can fix

**Status:** accepted

## Decision

Three checks gate publishing: **fixable HIGH/CRITICAL OS-package vulnerabilities**
(`ignore-unfixed`, `vuln-type: os`), **secrets at any severity** (in images, and in the
working tree via `security.yml`), and **mirror integrity** — the `mirror` job fails the run if an
upstream tag cannot be resolved to a digest, or if the mirrored copy does not resolve back to that
same digest (see [0001](0001-mirror-upstream-bases.md), "Digest control"). Everything else —
library vulnerabilities, Dockerfile misconfiguration, license findings, the zizmor workflow audit,
the git-history secret scan — is **reported**: printed to logs, kept as 90-day artifacts, and
uploaded to code scanning, but never red.

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

## Consequences

- A green publish means: built, smoke-tested, both platforms asserted present, no fixable
  HIGH/CRITICAL OS vulns, no secrets, and every base mirrored by verified digest — and nothing
  more. SECURITY.md spells out the same scope for reporters.
- The weekly rebuild is what turns "fixable" into "fixed"; the gate is what guarantees the
  rebuild picked the fix up.
- A mirror-verify failure blocks the `image` job entirely (it depends on `mirror`), so a bad
  mirror never reaches a build the way an unfixed library finding is allowed to.

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
