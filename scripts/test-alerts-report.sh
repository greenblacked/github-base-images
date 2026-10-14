#!/usr/bin/env bash
# Offline tests for scripts/alerts-report.sh, the daily report over every open
# security alert. No network, no token: the inputs are small hand-written
# copies of what the code-scanning and Dependabot APIs return.
#
# Checked: the exit code (0 clean, 1 untrustworthy, 3 fixable), what counts as
# fixable, excepted and not actionable, and the compact list it prints to the
# job log -- the one place the maintainer reads alerts from without
# downloading an artifact.
#
#   ./scripts/test-alerts-report.sh      # run by scripts/lint.sh, so CI runs it too
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$here/alerts-report.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

future=$(date -u -d '+30 days' +%Y-%m-%d 2>/dev/null || date -u -v+30d +%Y-%m-%d)
past=$(date -u -d '-3 days' +%Y-%m-%d 2>/dev/null || date -u -v-3d +%Y-%m-%d)

cat > "$work/images.json" <<'EOF'
[{"image": "ci-go"}, {"image": "ci-node22"}]
EOF

# trivy NUMBER CATEGORY RULE SEV PKG INSTALLED FIXED PATH -- one Trivy alert.
trivy() {
  jq -n --argjson n "$1" --arg cat "$2" --arg rule "$3" --arg sev "$4" \
        --arg pkg "$5" --arg inst "$6" --arg fixed "$7" --arg path "$8" '{
    number: $n, html_url: "https://example/\($n)",
    tool: {name: "Trivy"}, rule: {id: $rule, security_severity_level: $sev},
    most_recent_instance: {category: $cat,
      message: {text: "Package: \($pkg)\nInstalled Version: \($inst)\nVulnerability \($rule)\nSeverity: \($sev | ascii_upcase)\nFixed Version: \($fixed)\nLink: [\($rule)](https://x)"},
      location: {path: $path, start_line: 1}}}'
}
# repo NUMBER TOOL CATEGORY RULE SEV PATH LINE -- one repository-level alert.
repo() {
  jq -n --argjson n "$1" --arg tool "$2" --arg cat "$3" --arg rule "$4" --arg sev "$5" \
        --arg path "$6" --argjson line "$7" '{
    number: $n, html_url: "", tool: {name: $tool},
    rule: {id: $rule, security_severity_level: $sev},
    most_recent_instance: {category: $cat, message: {text: "line one\n::error::not a command"},
      location: {path: $path, start_line: $line}}}'
}
osv() {
  jq -n --argjson n "$1" --arg cat "$2" '{
    number: $n, tool: {name: "osv-scanner"}, rule: {id: "CVE-2024-9", security_severity_level: "high"},
    most_recent_instance: {category: $cat, message: {text: "Package '"'"'zlib@1'"'"' is vulnerable"},
      location: {path: "sbom.cdx.json"}}}'
}

{
  echo '['
  trivy 1 ci-go-amd64 CVE-2025-1000 high openssl 3.0.1 3.0.2 usr/lib/libssl.so; echo ,
  trivy 2 ci-go-arm64 CVE-2025-1001 critical golang.org/x/net 0.1.0 0.2.0 usr/local/bin/tool; echo ,
  # Unfixed: not actionable, left from before.
  trivy 3 ci-go-amd64 CVE-2025-2000 high libc6 2.36 "" debian; echo ,
  # Excepted: covered by an active entry below.
  trivy 4 ci-node22-amd64 CVE-2025-3000 high undici 6.0.0 6.21.0 usr/local/lib/node_modules/npm/node_modules/undici/package.json; echo ,
  # Covered by an EXPIRED entry: fixable again.
  trivy 5 ci-node22-arm64 CVE-2025-3001 high brace-expansion 2.0.1 2.0.2 usr/local/lib/node_modules/npm/node_modules/brace-expansion/package.json; echo ,
  # Fixable but MEDIUM: not actionable here.
  trivy 6 ci-node22-amd64 CVE-2025-4000 medium tar 1.0 1.1 x; echo ,
  osv 7 osv-ci-go-amd64; echo ,
  # Stale image category.
  trivy 8 ci-old-amd64 CVE-2025-5000 high openssl 1 2 y; echo ,
  repo 9 zizmor workflow-audit unpinned-uses high ".github/workflows/a##[error]b.yml" 12; echo ,
  repo 10 Scorecard scorecard BranchProtectionID high no-file null
  echo ']'
} > "$work/cs.json"

cat > "$work/exc.json" <<EOF
[
  {"image": "ci-node22", "id": "CVE-2025-3000", "package": "undici", "installed": "6.0.0",
   "reason": "bundled in npm", "upstream": "https://x", "expires": "$future",
   "paths": ["usr/local/lib/node_modules/npm/node_modules/undici/package.json"]},
  {"image": "ci-node22", "id": "CVE-2025-3001", "package": "brace-expansion", "installed": "2.0.1",
   "reason": "bundled in npm", "upstream": "https://x", "expires": "$past",
   "purls": ["pkg:npm/brace-expansion@2.0.1"]}
]
EOF

cat > "$work/dep.json" <<'EOF'
[{"number": 1, "dependency": {"package": {"name": "lodash", "ecosystem": "npm"}, "manifest_path": "package-lock.json"},
  "security_vulnerability": {"severity": "high", "vulnerable_version_range": "< 4.17.21", "first_patched_version": {"identifier": "4.17.21"}},
  "security_advisory": {"ghsa_id": "GHSA-aaaa-bbbb-cccc", "cve_id": "CVE-2021-1"}},
 {"number": 2, "dependency": {"package": {"name": "left-pad", "ecosystem": "npm"}, "manifest_path": "package-lock.json"},
  "security_vulnerability": {"severity": "high", "vulnerable_version_range": "< 2", "first_patched_version": null},
  "security_advisory": {"ghsa_id": "GHSA-dddd-eeee-ffff"}}]
EOF

# run CS DEP EXC -- sets rc, out (stdout), err.
run() {
  rc=0
  GITHUB_STEP_SUMMARY="" "$script" "$1" "$2" "$work/images.json" "$3" "$work/report.md" \
    > "$work/out" 2> "$work/err" || rc=$?
}
has() { grep -qF -- "$1" "$work/out"; }

echo "mixed alerts"
run "$work/cs.json" "$work/dep.json" "$work/exc.json"
check "exit 3 (fixable alerts open)" [ "$rc" -eq 3 ]
check "report written" [ -s "$work/report.md" ]
check "summary line is last on stdout" bash -c "tail -n 1 '$work/out' | grep -q '^alerts-report: code scanning 10 open (7 image, 1 stale, 2 repo-level), 3 fixable HIGH/CRITICAL, 1 excepted, 3 not actionable'"
check "log lists the fixable openssl alert with installed -> fixed" has "  - ci-go amd64  CVE-2025-1000  HIGH  openssl 3.0.1 -> 3.0.2  #1"
check "log lists the fixable Go module alert" has "  - ci-go arm64  CVE-2025-1001  CRITICAL  golang.org/x/net 0.1.0 -> 0.2.0  #2"
check "log lists the alert whose exception expired" has "CVE-2025-3001  HIGH  brace-expansion 2.0.1 -> 2.0.2  #5"
check "log does not list the excepted alert" bash -c "! grep -q 'CVE-2025-3000' '$work/out'"
check "log does not list the unfixed alert as fixable" bash -c "! grep -q 'CVE-2025-2000' '$work/out'"
check "log counts fixable code-scanning alerts" has "Fixable HIGH/CRITICAL code-scanning alerts, not excepted (3):"
check "log lists the fixable Dependabot alert" has "  - npm lodash (package-lock.json)  GHSA-aaaa-bbbb-cccc/CVE-2021-1  HIGH  < 4.17.21 -> 4.17.21  #1"
check "log omits the unpatched Dependabot alert" bash -c "! grep -q left-pad '$work/out'"
check "log lists a repo-level alert as tool, rule, path:line, severity" has "  - zizmor  unpinned-uses  .github/workflows/a## [error]b.yml:12  high  [workflow-audit]  #9"
check "log lists a repo-level alert with no line" has "  - Scorecard  BranchProtectionID  no-file  high  [scorecard]  #10"
check "log counts repo-level alerts" has "Repository-level code-scanning alerts (2):"
check "log groups not-actionable leftovers by category" has "Not-actionable image alerts left from before, closing on each category's next upload (3):"
check "  ... ci-go-amd64 Trivy" has "  - ci-go-amd64  Trivy  1 alert(s)"
check "  ... osv-ci-go-amd64" has "  - osv-ci-go-amd64  osv-scanner  1 alert(s)"
check "  ... ci-node22-amd64 (fixable MEDIUM)" has "  - ci-node22-amd64  Trivy  1 alert(s)"
check "no stdout line can be read as a workflow command" bash -c "! grep -qE '^[[:space:]]*::' '$work/out' && ! grep -qF '##[' '$work/out'"
check "report has the not-actionable section" grep -q '^### Not-actionable image alerts, left from before' "$work/report.md"
check "report names the inventory artifacts" grep -q 'security-report-<image>-<arch>' "$work/report.md"
check "report lists the expired exception" grep -q 'CVE-2025-3001 | brace-expansion | ci-node22 | '"$past" "$work/report.md"

echo "only actionable alerts, all excepted: clean"
{ echo '['; trivy 4 ci-node22-amd64 CVE-2025-3000 high undici 6.0.0 6.21.0 usr/local/lib/node_modules/npm/node_modules/undici/package.json; echo ']'; } > "$work/cs2.json"
echo '[]' > "$work/dep2.json"
run "$work/cs2.json" "$work/dep2.json" "$work/exc.json"
check "exit 0" [ "$rc" -eq 0 ]
check "empty lists say (0)" has "Fixable HIGH/CRITICAL code-scanning alerts, not excepted (0):"
check "no leftovers" has "closing on each category's next upload (0):"

echo "not-actionable leftovers alone never fail the report"
{ echo '['; trivy 3 ci-go-amd64 CVE-2025-2000 high libc6 2.36 "" debian; echo ,; osv 7 osv-ci-go-arm64; echo ']'; } > "$work/cs3.json"
run "$work/cs3.json" "$work/dep2.json" '/dev/null'
check "an exceptions path that is not a regular file is exit 1" [ "$rc" -eq 1 ]
echo '[]' > "$work/exc0.json"
run "$work/cs3.json" "$work/dep2.json" "$work/exc0.json"
check "exit 0 with 2 leftovers" [ "$rc" -eq 0 ]
check "summary counts 2 not actionable" bash -c "tail -n 1 '$work/out' | grep -q '2 not actionable'"

echo "the log is capped"
{
  echo '['
  for i in $(seq 1 250); do
    [ "$i" -eq 1 ] || echo ,
    trivy "$i" ci-go-amd64 "CVE-2025-$((10000 + i))" high "pkg$i" 1 2 p
  done
  echo ']'
} > "$work/cs4.json"
run "$work/cs4.json" "$work/dep2.json" "$work/exc0.json"
check "exit 3" [ "$rc" -eq 3 ]
check "at most 200 listed lines + the overflow note + the summary line" [ "$(wc -l < "$work/out")" -eq 202 ]
check "overflow note says how many were left out" has "- ... 54 more line(s) not shown; report.md (artifact code-scanning-report) has every alert"

echo "undecidable input still fails"
{ echo '['; jq -n '{number: 1, tool: {name: "Trivy"}, rule: {id: "CVE-1", security_severity_level: "high"},
  most_recent_instance: {category: "ci-go-amd64", message: {text: "Package: x\nInstalled Version: 1"}}}'; echo ']'; } > "$work/cs5.json"
run "$work/cs5.json" "$work/dep2.json" "$work/exc0.json"
check "a Trivy alert with no Fixed Version: line is exit 1" [ "$rc" -eq 1 ]

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
