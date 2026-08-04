# 0003 — Security gates block only what this repo can fix

**Status:** accepted

## Decision

Two checks gate publishing: **fixable HIGH/CRITICAL OS-package vulnerabilities**
(`ignore-unfixed`, `vuln-type: os`) and **secrets at any severity** (in images, and in the
working tree via `security.yml`). Everything else — library vulnerabilities, Dockerfile
misconfiguration, license findings, the zizmor workflow audit, the git-history secret scan — is
**reported**: printed to logs, kept as 90-day artifacts, and uploaded to code scanning, but never
red.

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

## Consequences

- A green publish means: built, smoke-tested, both platforms asserted present, no fixable
  HIGH/CRITICAL OS vulns, no secrets — and nothing more. SECURITY.md spells out the same scope
  for reporters.
- The weekly rebuild is what turns "fixable" into "fixed"; the gate is what guarantees the
  rebuild picked the fix up.

## Revisit if

An image ever vendors third-party libraries directly (library findings would become actionable),
or a gate starts flapping on findings with no available fix — that is the signal the scope
drifted, not that the gate should be muted.
