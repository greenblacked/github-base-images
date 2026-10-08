#!/usr/bin/env bash
# Offline tests for scripts/vuln-gate.sh, the vulnerability gate's comparison
# of a candidate build against the published image, and for
# scripts/vuln-baseline.sh, which finds that published image (case 8). No
# network, no Trivy, no registry: every report is a small Trivy JSON file
# written below, in the shape Trivy 0.70 writes (SchemaVersion 2,
# Results[].Vulnerabilities[]), and the registry is a fake docker on PATH.
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
check "the new finding is listed in the blocking table" in_summary "| CVE-2026-102268 | PyJWT | python-pkg | CRITICAL | 2.13.0 | 2.13.1 | Python |"
check "the known one is listed as known, not as blocking" \
  bash -c "grep -A3 '#### Known upstream' '$sum' | grep -qF 'CVE-2026-97687 (urllib3, python-pkg)'"
check "the summary names the baseline it compared with" in_summary "ghcr.io/o/ci-test@sha256:abc"
check "the log names the new finding" grep -q '^new: CVE-2026-102268 in PyJWT \[python-pkg\]' "$out"
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

echo "case 2c: the package type is part of the identity, the path is not"
# typed FILE TYPE TARGET FINDING -- one result of the given type and target.
typed() {
  jq -n --arg type "$2" --arg t "$3" --argjson v "$4" \
    '{SchemaVersion: 2, ArtifactName: "ci-test:test", Results: [{Target: $t, Class: "x", Type: $type, Vulnerabilities: [$v]}]}' > "$1"
}
SSL=$(vuln CVE-2026-55555 openssl 3.0.15-1 3.0.16-1)
SSL_NPM=$(vuln CVE-2026-55555 openssl 1.2.0 1.2.1)
typed "$work/base2c.json" debian "ci-test:test (debian 12.12)" "$SSL"
typed "$work/cand2c.json" node-pkg "usr/lib/node_modules/openssl/package.json" "$SSL_NPM"
run_gate --candidate "$work/cand2c.json" --baseline "$work/base2c.json"
check "a CVE known in a Debian package does not hide it in an npm package of that name: exit 3" [ "$rc" -eq 3 ]
check "  the npm finding is new" in_summary "| CVE-2026-55555 | openssl | node-pkg | HIGH | 1.2.0 | 1.2.1 |"
check "  the Debian one is fixed" in_summary "| CVE-2026-55555 | openssl | debian | HIGH | 3.0.15-1 | 3.0.16-1 |"
typed "$work/cand2d.json" debian "some/other/target" "$SSL"
run_gate --candidate "$work/cand2d.json" --baseline "$work/base2c.json"
check "the same id, package and type at another path is known: exit 0" [ "$rc" -eq 0 ]
# No Type: the Class stands in for it.
jq '.Results[0] |= del(.Type)' "$work/base2c.json" > "$work/base2e.json"
jq '.Results[0] |= (del(.Type) | .Target = "elsewhere")' "$work/base2c.json" > "$work/cand2e.json"
run_gate --candidate "$work/cand2e.json" --baseline "$work/base2e.json"
check "with no Type, the same Class matches: exit 0" [ "$rc" -eq 0 ]

echo "case 3: a finding gone from the build -> passes, listed as fixed"
report "$work/base3.json" "$URLLIB" "$OPENSSL"
report "$work/cand3.json" "$URLLIB"
run_gate --candidate "$work/cand3.json" --baseline "$work/base3.json"
check "exit 0" [ "$rc" -eq 0 ]
check "1 fixed" in_summary "| fixed by this build | 1 |"
check "the fixed finding is listed" in_summary "| CVE-2026-11111 | openssl | python-pkg | HIGH | 3.0.15-1 | 3.0.16-1 | Python |"
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
  Results: [{Target: $t, Class: "lang-pkgs", Vulnerabilities: [range(0; 3000) | {VulnerabilityID: "CVE-2026-\(.)", PkgName: "pkg\(.)", InstalledVersion: "1", FixedVersion: "2", Severity: "HIGH"}]}]}' \
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
check "a long cell is cut" bash -c "grep -q '^| CVE-2027-0 | new0 | lang-pkgs | CRITICAL | 1 | 2 | usr/lib/node_modules/npm/node_modules/0*… |\$' '$sum'"
# A pipe or a newline in a value must not break the table row.
jq '.Results[1].Target = "a|b\nc" | .Results[1].Vulnerabilities[0].PkgName = "p|q"' "$work/good.json" > "$work/pipe.json"
run_gate --candidate "$work/pipe.json" --no-baseline "strict for the test"
check "a pipe in a cell is escaped, a newline flattened" in_summary '| CVE-2026-97687 | p\|q | python-pkg | HIGH | 2.7.0 | 2.7.1 | a\|b c |'

echo "case 8: vuln-baseline.sh -- finding the published per-arch image"
baseline="$here/vuln-baseline.sh"
mkdir -p "$work/bin"
# The fake: answers `docker buildx imagetools inspect --raw` with the next
# word of FAKE_DOCKER (ok: the index in FAKE_INDEX; notfound; err), and logs
# each call. sleep is faked too, logging how long it was asked to wait.
cat > "$work/bin/docker" <<'EOF2'
#!/usr/bin/env bash
# `docker login`: record where the credential went and what it was, then
# succeed or fail as FAKE_LOGIN says.
if [ "$1" = login ]; then
  printf '%s %s %s\n' "$*" "${DOCKER_CONFIG:-unset}" "$(cat)" >> "$FAKE_LOGIN_LOG"
  [ -n "${DOCKER_CONFIG:-}" ] && echo '{"auths":{"ghcr.io":{}}}' > "$DOCKER_CONFIG/config.json"
  [ "${FAKE_LOGIN:-ok}" = ok ] || { echo "Error response from daemon: denied" >&2; exit 1; }
  exit 0
fi
# Every other call: which config it read its credentials from.
echo "${DOCKER_CONFIG:-unset}" >> "$FAKE_LOGIN_LOG.reads"
n=$(( $(cat "$FAKE_DOCKER_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DOCKER_COUNT"
read -r -a plan <<< "$FAKE_DOCKER"
case "${plan[$((n - 1))]:-err}" in
  ok) cat "$FAKE_INDEX" ;;
  notfound) echo "ERROR: ghcr.io/o/ci-test:v1: not found" >&2; exit 1 ;;
  denied) echo "ERROR: denied: unauthenticated request to private package" >&2; exit 1 ;;
  *) echo "ERROR: failed to do request: Head https://ghcr.io/v2/o/ci-test/manifests/v1: 502 Bad Gateway" >&2; exit 1 ;;
esac
EOF2
cat > "$work/bin/sleep" <<'EOF2'
#!/usr/bin/env bash
echo "$1" >> "$FAKE_SLEEP_LOG"
EOF2
chmod +x "$work/bin/docker" "$work/bin/sleep"
AMD=sha256:$(printf '%064d' 1); ARM=sha256:$(printf '%064d' 2)
jq -n --arg a "$AMD" --arg r "$ARM" '{mediaType: "application/vnd.oci.image.index.v1+json", manifests: [
  {digest: $a, platform: {os: "linux", architecture: "amd64"}},
  {digest: $r, platform: {os: "linux", architecture: "arm64"}},
  {digest: "sha256:\(("3" * 64))", platform: {os: "unknown", architecture: "unknown"}}]}' > "$work/index.json"
# run_base PLAN ARCH -- sets rc, bout (stdout), gho (the GITHUB_OUTPUT file).
run_base() {
  gho="$work/gho"; bout="$work/bout"; : > "$gho"; rm -f "$work/count" "$work/sleeps" "$work/login" "$work/login.reads"; rc=0
  PATH="$work/bin:$PATH" FAKE_DOCKER="$1" FAKE_INDEX="${INDEX:-$work/index.json}" FAKE_DOCKER_COUNT="$work/count" \
    FAKE_SLEEP_LOG="$work/sleeps" FAKE_LOGIN_LOG="$work/login" GITHUB_OUTPUT="$gho" \
    "$baseline" ghcr.io/o/ci-test v1 "$2" > "$bout" 2>&1 || rc=$?
}
outv() { sed -n "s/^$1=//p" "$gho"; }
calls() { cat "$work/count" 2>/dev/null || echo 0; }
run_base "ok" arm64
check "found: exit 0" [ "$rc" -eq 0 ]
check "  ref is the arm64 manifest, by digest" [ "$(outv ref)" = "ghcr.io/o/ci-test@$ARM" ]
check "  no note" [ -z "$(outv note)" ]
check "  one read" [ "$(calls)" -eq 1 ]
run_base "err err ok" amd64
check "two registry errors, then found: the amd64 manifest" [ "$(outv ref)" = "ghcr.io/o/ci-test@$AMD" ]
check "  three reads, waiting 5s then 15s" [ "$(calls):$(paste -sd, "$work/sleeps")" = "3:5,15" ]
check "  each retry is a warning" [ "$(grep -c '^::warning::reading ghcr.io/o/ci-test:v1 failed' "$bout")" -eq 2 ]
run_base "err err err err" amd64
check "registry errors throughout: exit 0, never a failed step" [ "$rc" -eq 0 ]
check "  four reads, waiting 5s, 15s, 45s" [ "$(calls):$(paste -sd, "$work/sleeps")" = "4:5,15,45" ]
check "  no ref: strict" [ -z "$(outv ref)" ]
check "  the note says it could not read, after 4 attempts" bash -c "sed -n 's/^note=//p' '$gho' | grep -q 'could not read ghcr.io/o/ci-test:v1 from the registry after 4 attempts (exit 1: ERROR: failed to do request'"
check "  a warning that the gate runs strict" grep -q '^::warning::could not read .* -- the vulnerability gate runs strict for amd64' "$bout"
run_base "notfound" amd64
check "never published: no ref" [ -z "$(outv ref)" ]
check "  not retried" [ "$(calls):$(cat "$work/sleeps" 2>/dev/null)" = "1:" ]
check "  a notice, not a warning" grep -q '^::notice::ghcr.io/o/ci-test:v1 has never been published (new image or new tag)' "$bout"
run_base "err notfound" amd64
check "an error, then not found: strict after two reads" [ "$(calls):$(outv ref)" = "2:" ]
jq '.manifests |= map(select(.platform.architecture != "arm64"))' "$work/index.json" > "$work/index-amd.json"
INDEX="$work/index-amd.json" run_base "ok" arm64
check "an index with no linux/arm64: strict, with a warning" bash -c "[ -z \"\$(sed -n 's/^ref=//p' '$gho')\" ] && grep -q '^::warning::the published ghcr.io/o/ci-test:v1 has no single linux/arm64 manifest' '$bout'"
jq '.manifests[0]' "$work/index.json" > "$work/single.json"
INDEX="$work/single.json" run_base "ok" amd64
check "a single manifest, not an index: strict" [ -z "$(outv ref)" ]
rc=0; "$baseline" only-two args > /dev/null 2>&1 || rc=$?
check "usage: exit 2" [ "$rc" -eq 2 ]
check "no credentials given: anonymous, no login" [ ! -e "$work/login" ]
REGISTRY_USER='' REGISTRY_TOKEN='' run_base "denied denied denied denied" amd64
check "private baseline without credentials: no login" [ ! -e "$work/login" ]
check "  no ref, with an explicit denial reason" bash -c "[ -z \"\$(sed -n 's/^ref=//p' '$gho')\" ] && grep -q 'unauthenticated request to private package' '$gho'"
run_gate --candidate "$work/cand1.json" --no-baseline "$(outv note)"
check "  all candidate findings block rather than being treated as known" [ "$rc" -eq 3 ]
check "  strict gate reports both findings as new" in_summary "| **new in this build (blocking)** | **2** |"
# With credentials: logged in to the registry, through a throwaway config.
REGISTRY_USER=bot REGISTRY_TOKEN=s3cret run_base "ok" amd64
check "with credentials: found" [ "$(outv ref)" = "ghcr.io/o/ci-test@$AMD" ]
cfg=$(awk '{print $(NF-1)}' "$work/login" 2>/dev/null || true)
check "  logged in to ghcr.io as the user, token on stdin, not argv" bash -c "grep -q '^login ghcr.io --username bot --password-stdin .* s3cret\$' '$work/login'"
check "  into a throwaway DOCKER_CONFIG, not the user's" bash -c "[ -n '$cfg' ] && [ '$cfg' != unset ] && [ '$cfg' != \"\$HOME/.docker\" ]"
check "  the registry read used that config" [ "$(sort -u "$work/login.reads")" = "$cfg" ]
check "  and it is gone afterwards, credential and all" [ ! -e "$cfg" ]
check "  the token is not in the output" bash -c "! grep -q s3cret '$bout' '$gho'"
# The login fails: strict, with a warning, and no registry read.
REGISTRY_USER=bot REGISTRY_TOKEN=s3cret FAKE_LOGIN=fail run_base "ok" amd64
check "login refused: exit 0, strict" [ "$rc:$(outv ref)" = "0:" ]
check "  a warning naming the login" grep -q '^::warning::could not log in to ghcr.io to read ghcr.io/o/ci-test:v1 (exit 1: Error response from daemon: denied' "$bout"
check "  nothing read after it" [ "$(calls)" -eq 0 ]
cfg=$(awk '{print $(NF-1)}' "$work/login")
check "  and the throwaway config is gone" [ ! -e "$cfg" ]

echo "case 9: baseline credentials are main-only, never passed to PR code"
workflow="$here/../.github/workflows/build-image.yml"
for var in REGISTRY_USER REGISTRY_TOKEN TRIVY_USERNAME TRIVY_PASSWORD; do
  case "$var" in
    REGISTRY_USER|TRIVY_USERNAME) value=github.actor ;;
    *) value=github.token ;;
  esac
  expected="$var: \${{ github.event_name != 'pull_request' && github.ref == 'refs/heads/main' && $value || '' }}"
  check "$var is empty for PRs and non-main refs" grep -qF "$expected" "$workflow"
done

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
