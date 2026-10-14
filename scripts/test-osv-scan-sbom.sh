#!/usr/bin/env bash
# Offline tests for scripts/osv-scan-sbom.sh, the OSV second opinion run on
# every image's SBOM. No network, no database: osv-scanner is a fake on PATH
# that copies the SBOM it was given aside, writes a canned SARIF and exits
# with a chosen status.
#
# What matters here is what reaches code scanning: since 2026-10-14 the
# upload SARIF is an empty run (docs/adr/0003), which is what keeps every
# `osv-<image>-<arch>` category closed. A regression that put findings back
# into it would refill the code-scanning page with thousands of unfixed
# alerts, and one that uploaded a failed scan would pass it off as clean.
#
#   ./scripts/test-osv-scan-sbom.sh      # run by scripts/lint.sh, so CI runs it too
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$here/osv-scan-sbom.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$work/bin"
# The fake osv-scanner: copies the -L file to FAKE_OSV_SEEN, writes
# FAKE_OSV_SARIF (when set) to --output-file, exits FAKE_OSV_RC.
cat > "$work/bin/osv-scanner" <<'EOF'
#!/usr/bin/env bash
outf="" lock=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-file) outf="$2"; shift ;;
    -L) lock="$2"; shift ;;
  esac
  shift
done
if [ -n "$lock" ]; then cp "$lock" "$FAKE_OSV_SEEN"; fi
if [ -n "${FAKE_OSV_SARIF:-}" ] && [ -n "$outf" ]; then cp "$FAKE_OSV_SARIF" "$outf"; fi
exit "${FAKE_OSV_RC:-0}"
EOF
chmod +x "$work/bin/osv-scanner"

# An SBOM the way Trivy writes one: a Debian binary whose source differs
# (libssl3 from openssl), with the point release in the distro qualifier, and
# one npm package.
cat > "$work/sbom-ci-test-amd64.cdx.json" <<'EOF'
{"bomFormat": "CycloneDX", "components": [
  {"bom-ref": "a", "name": "libssl3", "version": "3.0.17-1~deb12u2",
   "purl": "pkg:deb/debian/libssl3@3.0.17-1~deb12u2?arch=amd64&distro=debian-12.12",
   "properties": [{"name": "aquasecurity:trivy:SrcName", "value": "openssl"},
                  {"name": "aquasecurity:trivy:SrcVersion", "value": "3.0.17"},
                  {"name": "aquasecurity:trivy:SrcRelease", "value": "1~deb12u2"}]},
  {"bom-ref": "b", "name": "undici", "version": "6.0.0", "purl": "pkg:npm/undici@6.0.0"}
], "dependencies": [{"ref": "a", "dependsOn": []}]}
EOF
# Same SBOM with Trivy's source properties gone: the tripwire case.
jq '.components |= map(del(.properties))' "$work/sbom-ci-test-amd64.cdx.json" > "$work/nosrc.cdx.json"

# osv-scanner's SARIF: one scored HIGH, one scored LOW, one unscored.
cat > "$work/findings.sarif" <<'EOF'
{"version": "2.1.0", "runs": [{
  "tool": {"driver": {"name": "osv-scanner", "version": "2.6.0", "rules": [
    {"id": "CVE-2025-0001", "properties": {"security-severity": "7.5"}},
    {"id": "CVE-2025-0002", "properties": {"security-severity": "3.1"}},
    {"id": "GHSA-aaaa-bbbb-cccc"}]}},
  "artifacts": [{"location": {"uri": "file:///tmp/osv-scan-sbom/sbom-ci-test-amd64.cdx.json"}}],
  "results": [
    {"ruleId": "CVE-2025-0001", "message": {"text": "Package 'openssl@3.0.17-1~deb12u2' is vulnerable to 'CVE-2025-0001'."},
     "locations": [{"physicalLocation": {"artifactLocation": {"uri": "file:///tmp/osv-scan-sbom/sbom-ci-test-amd64.cdx.json"}}}]},
    {"ruleId": "CVE-2025-0002", "message": {"text": "Package 'openssl@3.0.17-1~deb12u2' is vulnerable to 'CVE-2025-0002'."},
     "locations": [{"physicalLocation": {"artifactLocation": {"uri": "file:///tmp/osv-scan-sbom/sbom-ci-test-amd64.cdx.json"}}}]},
    {"ruleId": "GHSA-aaaa-bbbb-cccc", "message": {"text": "Package 'undici@6.0.0' is vulnerable to 'GHSA-aaaa-bbbb-cccc'."},
     "locations": [{"physicalLocation": {"artifactLocation": {"uri": "file:///tmp/osv-scan-sbom/sbom-ci-test-amd64.cdx.json"}}}]}
  ]}]}
EOF
jq '.runs[0].results = []' "$work/findings.sarif" > "$work/none.sarif"

# run SBOM SARIF RC -- runs the script; sets rc and out, leaves full.sarif
# and upload.sarif (if any) in $work/o.
run() {
  rm -rf "$work/o" "$work/seen.cdx.json"; mkdir -p "$work/o"
  out="$work/out"; rc=0
  PATH="$work/bin:$PATH" FAKE_OSV_SEEN="$work/seen.cdx.json" FAKE_OSV_SARIF="$2" FAKE_OSV_RC="$3" \
    GITHUB_STEP_SUMMARY="" \
    "$script" "$1" "$work/o/full.sarif" "$work/o/upload.sarif" > "$out" 2>&1 || rc=$?
}
jqf() { jq -e "$1" "$2" > /dev/null 2>&1; }

echo "findings (osv-scanner exit 1): kept in full.sarif, none uploaded"
run "$work/sbom-ci-test-amd64.cdx.json" "$work/findings.sarif" 1
check "exit 0" [ "$rc" -eq 0 ]
check "full.sarif keeps all three findings" jqf '[.runs[].results[]] | length == 3' "$work/o/full.sarif"
check "full.sarif shows the SBOM's name, not the work path" \
  jqf '[.runs[].results[].locations[].physicalLocation.artifactLocation.uri] | unique == ["sbom-ci-test-amd64.cdx.json"]' "$work/o/full.sarif"
check "upload.sarif exists and is valid SARIF with one run" jqf '.runs | length == 1' "$work/o/upload.sarif"
check "upload.sarif has no results" jqf '[.runs[].results[]] | length == 0' "$work/o/upload.sarif"
check "upload.sarif's results key is present (an empty list, not missing)" jqf 'all(.runs[]; .results == [])' "$work/o/upload.sarif"
check "upload.sarif is still osv-scanner's run" jqf '.runs[0].tool.driver.name == "osv-scanner" and .runs[0].tool.driver.version == "2.6.0"' "$work/o/upload.sarif"
check "upload.sarif carries no rules" jqf '.runs[0].tool.driver.rules == []' "$work/o/upload.sarif"
check "counts: 3 total, 1 scored >= 7.0, 1 below, 1 unscored" \
  grep -q '3 finding(s) in full.sarif (all severities): 1 with security-severity >= 7.0, 1 below, 1 with no score' "$out"
check "says the upload is empty by design" grep -q 'code-scanning upload is empty by design' "$out"
check "scanned the source package (openssl), not the binary (libssl3)" \
  jqf 'any(.components[]; .name == "openssl" and (.purl | startswith("pkg:deb/debian/openssl@")))' "$work/seen.cdx.json"
check "scanned with the major release only (debian-12)" \
  jqf 'any(.components[]; .purl | test("distro=debian-12$"))' "$work/seen.cdx.json"

echo "no findings (osv-scanner exit 0)"
run "$work/sbom-ci-test-amd64.cdx.json" "$work/none.sarif" 0
check "exit 0" [ "$rc" -eq 0 ]
check "upload.sarif written, empty" jqf '[.runs[].results[]] | length == 0' "$work/o/upload.sarif"

echo "a scan that did not complete leaves nothing to upload"
for code in 127 128 129 130; do
  run "$work/sbom-ci-test-amd64.cdx.json" "$work/none.sarif" "$code"
  check "osv-scanner exit $code -> exit 1, no SARIF left" \
    [ "$rc:$(test -e "$work/o/full.sarif" && echo full)$(test -e "$work/o/upload.sarif" && echo upload)" = "1:" ]
done
run "$work/sbom-ci-test-amd64.cdx.json" "" 0
check "exit 0 but no output file -> exit 1, nothing left" \
  [ "$rc:$(test -e "$work/o/upload.sarif" && echo upload)" = "1:" ]

echo "tripwire: Trivy's source properties missing"
cp "$work/nosrc.cdx.json" "$work/sbom-nosrc.cdx.json"
run "$work/sbom-nosrc.cdx.json" "$work/findings.sarif" 1
check "exit 1, no SARIF left" [ "$rc:$(test -e "$work/o/upload.sarif" && echo upload)" = "1:" ]

echo "usage"
rc=0; PATH="$work/bin:$PATH" "$script" "$work/sbom-ci-test-amd64.cdx.json" > /dev/null 2>&1 || rc=$?
check "one argument -> exit 2" [ "$rc" -eq 2 ]
cp "$work/sbom-ci-test-amd64.cdx.json" "$work/sbom.json"
run "$work/sbom.json" "$work/findings.sarif" 1
check "a name not ending in .cdx.json -> exit 2" [ "$rc" -eq 2 ]

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
