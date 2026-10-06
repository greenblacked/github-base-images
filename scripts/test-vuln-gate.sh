#!/usr/bin/env bash
# Offline tests for scripts/vuln-gate.sh, the vulnerability gate's comparison
# of a candidate build against the published image. No network, no Trivy:
# every input is a small Trivy JSON report written below, in the shape Trivy
# 0.70 writes (SchemaVersion 2, Results[].Vulnerabilities[]).
#
#   ./scripts/test-vuln-gate.sh        # run by scripts/lint.sh, so CI runs it too
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
gate="$here/vuln-gate.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# vuln ID PKG INSTALLED FIXED [SEVERITY] -- one finding, as a JSON object.
vuln() {
  jq -nc --arg id "$1" --arg pkg "$2" --arg inst "$3" --arg fix "$4" --arg sev "${5:-HIGH}" \
    '{VulnerabilityID: $id, PkgName: $pkg, InstalledVersion: $inst, FixedVersion: $fix,
      Severity: $sev, PkgIdentifier: {PURL: "pkg:pypi/\($pkg)@\($inst)"}, Title: "t"}'
}
# report FILE [FINDING...] -- a Trivy JSON report with the findings under one
# library target, plus an OS target with none (Trivy omits Vulnerabilities
# when a target has none, which must read as zero, not as an error).
report() {
  local f="$1"; shift
  printf '%s\n' "$@" | jq -s '{
      SchemaVersion: 2, ArtifactName: "ci-test:test", ArtifactType: "container_image",
      Results: [
        {Target: "ci-test:test (debian 12.12)", Class: "os-pkgs", Type: "debian"},
        ({Target: "Python", Class: "lang-pkgs", Type: "python-pkg", Vulnerabilities: .}
         | if (.Vulnerabilities | length) == 0 then del(.Vulnerabilities) else . end)
      ]}' > "$f"
}

# run_gate ARGS... -- sets rc, out (stdout+stderr), sum (the summary file).
run_gate() {
  sum="$work/summary.md"; out="$work/out"; rm -f "$sum"; rc=0
  "$gate" --label "ci-test (amd64)" --summary "$sum" "$@" > "$out" 2>&1 || rc=$?
}
in_summary() { grep -qF -- "$1" "$sum"; }
res() { jq -r "$1" "$work/result.json"; }

URLLIB=$(vuln CVE-2026-97687 urllib3 2.7.0 2.7.1)
URLLIB_NEWER=$(vuln CVE-2026-97687 urllib3 2.7.0.post1 2.7.1)
JWT=$(vuln CVE-2026-102268 PyJWT 2.13.0 2.13.1 CRITICAL)
OPENSSL=$(vuln CVE-2026-11111 openssl 3.0.15-1 3.0.16-1)

echo "case 1: a finding the published image does not have -> blocks"
report "$work/base1.json" "$URLLIB"
report "$work/cand1.json" "$URLLIB" "$JWT"
run_gate --candidate "$work/cand1.json" --baseline "$work/base1.json" \
  --baseline-ref ghcr.io/o/ci-test@sha256:abc --result "$work/result.json"
check "exit 3" [ "$rc" -eq 3 ]
check "summary counts 1 new" in_summary "| **new in this build (blocking)** | **1** |"
check "  1 known" in_summary "| known upstream (published image has them too) | 1 |"
check "the new finding is listed in the blocking table" in_summary "| CVE-2026-102268 | PyJWT | CRITICAL | 2.13.0 | 2.13.1 | Python |"
check "the known one is listed as known, not as blocking" \
  bash -c "grep -A3 '#### Known upstream' '$sum' | grep -qF 'CVE-2026-97687 (urllib3)'"
check "the summary names the baseline it compared with" in_summary "ghcr.io/o/ci-test@sha256:abc"
check "the log names the new finding" grep -q '^new: CVE-2026-102268 in PyJWT' "$out"
check "--result: new" [ "$(res '.new | map(.id) | join(",")')" = "CVE-2026-102268" ]
check "--result: known" [ "$(res '.known | map(.id) | join(",")')" = "CVE-2026-97687" ]
check "--result: not strict" [ "$(res '.baseline.strict')" = "false" ]

echo "case 2: the same CVE in the same package at a new version -> known, passes"
report "$work/base2.json" "$URLLIB"
report "$work/cand2.json" "$URLLIB_NEWER"
run_gate --candidate "$work/cand2.json" --baseline "$work/base2.json"
check "exit 0" [ "$rc" -eq 0 ]
check "0 new" in_summary "| **new in this build (blocking)** | **0** |"
check "1 known" in_summary "| known upstream (published image has them too) | 1 |"
check "no blocking table" bash -c "! grep -q 'New in this build' '$sum'"
# The same CVE id in a DIFFERENT package is a different identity.
report "$work/cand2b.json" "$(vuln CVE-2026-97687 requests 2.40.0 2.40.1)"
run_gate --candidate "$work/cand2b.json" --baseline "$work/base2.json"
check "the same CVE in another package -> new, exit 3" [ "$rc" -eq 3 ]

echo "case 3: a finding gone from the build -> passes, listed as fixed"
report "$work/base3.json" "$URLLIB" "$OPENSSL"
report "$work/cand3.json" "$URLLIB"
run_gate --candidate "$work/cand3.json" --baseline "$work/base3.json"
check "exit 0" [ "$rc" -eq 0 ]
check "1 fixed" in_summary "| fixed by this build | 1 |"
check "the fixed finding is listed" in_summary "| CVE-2026-11111 | openssl | HIGH | 3.0.15-1 | 3.0.16-1 | Python |"
# Everything fixed, nothing left: a clean candidate (no Vulnerabilities key).
report "$work/cand3b.json"
run_gate --candidate "$work/cand3b.json" --baseline "$work/base3.json"
check "a candidate with no findings at all: exit 0" [ "$rc" -eq 0 ]
check "  2 fixed" in_summary "| fixed by this build | 2 |"

echo "case 4: no baseline -> strict, every finding blocks"
run_gate --candidate "$work/cand1.json" --no-baseline "ghcr.io/o/ci-test:v1 has never been published" \
  --result "$work/result.json"
check "exit 3" [ "$rc" -eq 3 ]
check "2 new" in_summary "| **new in this build (blocking)** | **2** |"
check "the summary says it is strict, and why" in_summary "**Strict: no baseline.** ghcr.io/o/ci-test:v1 has never been published"
check "the log says strict" grep -q 'strict: no baseline' "$out"
check "--result: strict with the reason" [ "$(res '.baseline.strict, .baseline.reason' | paste -sd'|' -)" = "true|ghcr.io/o/ci-test:v1 has never been published" ]
run_gate --candidate "$work/cand3b.json" --no-baseline "could not read the registry"
check "strict, but a clean candidate: exit 0" [ "$rc" -eq 0 ]
run_gate --candidate "$work/cand1.json" --no-baseline ""
check "--no-baseline with no reason is a usage error" [ "$rc" -eq 2 ]

echo "case 5: malformed or unreadable input -> exit 1, never a pass"
report "$work/good.json" "$URLLIB"
bad_input() { # WHAT FILE-CONTENT-WRITER...
  local what="$1"; shift
  "$@" > "$work/bad.json"
  run_gate --candidate "$work/bad.json" --baseline "$work/good.json"
  check "candidate $what: exit 1" [ "$rc" -eq 1 ]
  run_gate --candidate "$work/good.json" --baseline "$work/bad.json"
  check "baseline $what: exit 1" [ "$rc" -eq 1 ]
}
bad_input "not JSON" echo 'Report Summary: not json'
bad_input "empty file" printf ''
bad_input "a JSON array" echo '[]'
bad_input "two JSON values" printf '%s\n%s\n' "$(cat "$work/good.json")" "$(cat "$work/good.json")"
bad_input "SchemaVersion 3" jq '.SchemaVersion = 3' "$work/good.json"
bad_input "no ArtifactName" jq 'del(.ArtifactName)' "$work/good.json"
bad_input "Results not an array" jq '.Results = {}' "$work/good.json"
bad_input "Vulnerabilities not an array" jq '.Results[1].Vulnerabilities = "x"' "$work/good.json"
bad_input "a finding with no PkgName" jq 'del(.Results[1].Vulnerabilities[0].PkgName)' "$work/good.json"
bad_input "a finding with an empty VulnerabilityID" jq '.Results[1].Vulnerabilities[0].VulnerabilityID = ""' "$work/good.json"
run_gate --candidate "$work/does-not-exist.json" --baseline "$work/good.json"
check "a missing candidate file: exit 1" [ "$rc" -eq 1 ]
check "  and the message names it" grep -q 'does-not-exist.json does not exist' "$out"
run_gate --candidate "$work/good.json" --baseline "$work/does-not-exist.json"
check "a missing baseline file: exit 1 (not strict -- strict is only ever asked for)" [ "$rc" -eq 1 ]
check "  and no summary is left behind to read as a result" [ ! -e "$sum" ]
# A report with no Results at all is how Trivy writes an image it found
# nothing in: zero findings, valid.
jq 'del(.Results)' "$work/good.json" > "$work/noresults.json"
run_gate --candidate "$work/noresults.json" --baseline "$work/good.json"
check "a report with no Results is zero findings: exit 0" [ "$rc" -eq 0 ]

echo "case 6: usage"
run_gate --candidate "$work/good.json"
check "neither --baseline nor --no-baseline: exit 2" [ "$rc" -eq 2 ]
run_gate --candidate "$work/good.json" --baseline "$work/good.json" --no-baseline "x"
check "both: exit 2" [ "$rc" -eq 2 ]
run_gate --candidate "$work/good.json" --baseline "$work/good.json" --bogus
check "an unknown flag: exit 2" [ "$rc" -eq 2 ]

echo "case 7: a huge report keeps the summary small, and cells table-safe"
# 3000 known findings and 200 new ones, each with a 240-character target
# name: the summary must stay far below the 1 MiB step-summary limit.
long=$(printf 'usr/lib/node_modules/npm/node_modules/%0200d' 0)
jq -n --arg t "$long" '{SchemaVersion: 2, ArtifactName: "big",
  Results: [{Target: $t, Vulnerabilities: [range(0; 3000) | {VulnerabilityID: "CVE-2026-\(.)", PkgName: "pkg\(.)", InstalledVersion: "1", FixedVersion: "2", Severity: "HIGH"}]}]}' \
  > "$work/bigbase.json"
jq '.Results[0].Vulnerabilities += [range(0; 200) | {VulnerabilityID: "CVE-2027-\(.)", PkgName: "new\(.)", InstalledVersion: "1", FixedVersion: "2", Severity: "CRITICAL"}]' \
  "$work/bigbase.json" > "$work/bigcand.json"
run_gate --candidate "$work/bigcand.json" --baseline "$work/bigbase.json"
check "exit 3" [ "$rc" -eq 3 ]
size=$(wc -c < "$sum")
check "summary is under 64 KiB ($size bytes)" [ "$size" -lt 65536 ]
check "the blocking table is cut, and says how many more" in_summary "...and 150 more"
check "the known list is cut, and says how many more" in_summary "+2960 more"
check "every new finding is still in the log" [ "$(grep -c '^new: ' "$out")" -eq 200 ]
check "a long cell is cut" bash -c "grep -q '^| CVE-2027-0 | new0 | CRITICAL | 1 | 2 | usr/lib/node_modules/npm/node_modules/0*… |\$' '$sum'"
# A pipe or a newline in a value must not break the table row.
jq '.Results[1].Target = "a|b\nc" | .Results[1].Vulnerabilities[0].PkgName = "p|q"' "$work/good.json" > "$work/pipe.json"
run_gate --candidate "$work/pipe.json" --no-baseline "strict for the test"
check "a pipe in a cell is escaped, a newline flattened" in_summary '| CVE-2026-97687 | p\|q | HIGH | 2.7.0 | 2.7.1 | a\|b c |'

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
