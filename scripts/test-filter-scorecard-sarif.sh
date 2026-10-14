#!/usr/bin/env bash
# Offline tests for scripts/filter-scorecard-sarif.sh, which drops the
# Scorecard findings this repository accepts by design
# (.github/scorecard-accepted.json) before the SARIF goes to code scanning.
#
# The fixture is shaped like scorecard-action v2.4.4's SARIF: one run, the
# checks as runs[0].tool.driver.rules (PinnedDependenciesID, ...), one result
# per finding with a ruleId and a single physicalLocation; repository-wide
# checks carry the uri "no file associated with this alert" and startLine 1.
# The checkout it points into is a small tree built here.
#
# What matters: an accepted line is dropped, a NEW unpinned line in the same
# file is not, nothing whose location cannot be resolved is dropped without a
# rule-wide entry, and a bad list or SARIF writes nothing at all. The last
# section runs the real list against the real tree, so a Dockerfile.ci whose
# FROM line stops matching (or a new image's) fails lint, not the Security tab.
#
#   ./scripts/test-filter-scorecard-sarif.sh   # run by scripts/lint.sh, so CI runs it too
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/.." && pwd)
script="$here/filter-scorecard-sarif.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# run <accepted> <in> <out> [extra args...]: runs the filter against the
# fixture checkout; sets rc and leaves stdout+stderr in $work/log.
run() {
  local acc="$1" in="$2" out="$3"; shift 3
  rc=0
  "$script" --accepted "$acc" --root "$work/repo" "$@" "$in" "$out" > "$work/log" 2>&1 || rc=$?
}
logged() { grep -qF -- "$1" "$work/log"; }
not_logged() { ! logged "$1"; }
quiet() { "$@" > /dev/null; }
kept_ids() { jq -r '[.runs[].results[] | "\(.ruleId) \(.locations[0].physicalLocation.artifactLocation.uri):\(.locations[0].physicalLocation.region.startLine)"] | sort | .[]' "$1"; }

# The literal Dockerfile line, ${...} and all.
# shellcheck disable=SC2016
from_line='FROM ${BASE_IMAGE}'

# --- The fixture checkout.
mkdir -p "$work/repo/ci-aaa" "$work/repo/ci-node9" "$work/repo/ci-cloud"
cat > "$work/repo/ci-aaa/Dockerfile.ci" <<'EOF'
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=debian:bookworm-slim

# comment
# comment

FROM ${BASE_IMAGE}
RUN pip install requests
EOF
cat > "$work/repo/ci-node9/Dockerfile.ci" <<'EOF'
ARG BASE_IMAGE=node:9
FROM ${BASE_IMAGE}
ARG NPM_VERSION=12.2.0
RUN npm install --global "npm@${NPM_VERSION}" \
    && rm -rf /root/.npm
RUN npm install --global left-pad
EOF
cat > "$work/repo/ci-cloud/Dockerfile.ci" <<'EOF'
FROM ${BASE_IMAGE}
RUN /opt/az/bin/python3 -m pip install --no-cache-dir \
        'PyJWT>=2.14.0'
EOF
printf '%s\r\n' "$from_line" > "$work/repo/crlf.Dockerfile"

cat > "$work/accepted.json" <<'EOF'
[
  {"rule": "PinnedDependenciesID", "path": "^ci-[a-z0-9]+/Dockerfile\\.ci$",
   "match": "^FROM \\$\\{BASE_IMAGE\\}\\s*$", "reason": "base passed as a tag by design"},
  {"rule": "PinnedDependenciesID", "path": "^ci-node[0-9]+/Dockerfile\\.ci$",
   "match": "^RUN npm install --global \"npm@\\$\\{NPM_VERSION\\}\"", "reason": "npm pinned by version"},
  {"rule": "PinnedDependenciesID", "path": "^crlf\\.Dockerfile$",
   "match": "^FROM \\$\\{BASE_IMAGE\\}$", "reason": "crlf"},
  {"rule": "CodeReviewID", "reason": "single maintainer"},
  {"rule": "FuzzingID", "reason": "nothing to fuzz"},
  {"rule": "CIIBestPracticesID", "reason": "optional badge"},
  {"rule": "TokenPermissionsID", "path": "^nowhere$", "match": "x", "reason": "never matches"}
]
EOF

# res <rule> <uri> <line> [text]: one Scorecard-style result.
res() {
  jq -cn --arg r "$1" --arg u "$2" --argjson l "$3" --arg t "${4:-finding}" '{
    ruleId: $r, ruleIndex: 0,
    message: {text: "score is 0: \($t)\nClick Remediation section below to solve this issue"},
    locations: [{physicalLocation: {
      region: {startLine: $l, endLine: $l, snippet: {text: $t}},
      artifactLocation: {uri: $u, uriBaseId: "%SRCROOT%"}},
      message: {text: $t}}]}'
}
nofile="no file associated with this alert"
# sarif <result>...: a scorecard-action v2.4.4-shaped log around the results.
sarif() {
  local r; for r in "$@"; do printf '%s\n' "$r"; done | jq -s '{
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json", version: "2.1.0",
    runs: [{
      automationDetails: {id: "supply-chain/local/1760450000"},
      tool: {driver: {name: "Scorecard", informationUri: "https://github.com/ossf/scorecard",
        semanticVersion: "v5.2.1",
        rules: (["BranchProtectionID", "CIIBestPracticesID", "CodeReviewID", "FuzzingID",
                 "MaintainedID", "PinnedDependenciesID", "TokenPermissionsID"]
                | map({id: ., name: (. | sub("ID$"; "")), shortDescription: {text: .},
                       defaultConfiguration: {level: "error"},
                       properties: {precision: "high", "problem.severity": "warning",
                                    "security-severity": "5.5", tags: ["supply-chain", "security"]}}))}},
      results: .}]}'
}

echo "accepted findings are dropped, the rest kept"
sarif \
  "$(res PinnedDependenciesID ci-aaa/Dockerfile.ci 7 'containerImage not pinned by hash')" \
  "$(res PinnedDependenciesID ci-aaa/Dockerfile.ci 8 'pipCommand not pinned by hash')" \
  "$(res PinnedDependenciesID ci-node9/Dockerfile.ci 2 'containerImage not pinned by hash')" \
  "$(res PinnedDependenciesID ci-node9/Dockerfile.ci 4 'npmCommand not pinned by hash')" \
  "$(res PinnedDependenciesID ci-node9/Dockerfile.ci 6 'npmCommand not pinned by hash')" \
  "$(res PinnedDependenciesID ci-cloud/Dockerfile.ci 1 'containerImage not pinned by hash')" \
  "$(res PinnedDependenciesID ci-cloud/Dockerfile.ci 2 'pipCommand not pinned by hash')" \
  "$(res PinnedDependenciesID crlf.Dockerfile 1 'containerImage not pinned by hash')" \
  "$(res CodeReviewID "$nofile" 1 'Found 2/30 approved changesets')" \
  "$(res FuzzingID "$nofile" 1 'project is not fuzzed')" \
  "$(res CIIBestPracticesID "$nofile" 1 'no effort to earn an OpenSSF best practices badge detected')" \
  "$(res BranchProtectionID "$nofile" 1 'branch protection not enabled on development/release branches')" \
  "$(res MaintainedID "$nofile" 1 'project was created in last 90 days')" \
  > "$work/in.sarif"
run "$work/accepted.json" "$work/in.sarif" "$work/out.sarif"
check "exits 0" [ "$rc" -eq 0 ]
cat > "$work/want" <<'EOF'
BranchProtectionID no file associated with this alert:1
MaintainedID no file associated with this alert:1
PinnedDependenciesID ci-aaa/Dockerfile.ci:8
PinnedDependenciesID ci-cloud/Dockerfile.ci:2
PinnedDependenciesID ci-node9/Dockerfile.ci:6
EOF
check "kept exactly: BranchProtection, Maintained, and the three unaccepted lines" \
  diff -u "$work/want" <(kept_ids "$work/out.sarif")
check "tool and rules are copied unchanged" \
  diff <(jq -S '.runs[0].tool, .runs[0].automationDetails, ."$schema", .version' "$work/in.sarif") \
       <(jq -S '.runs[0].tool, .runs[0].automationDetails, ."$schema", .version' "$work/out.sarif")
check "kept results are byte-identical to the input's" \
  diff <(jq -c '.runs[0].results[] | select(.ruleId == "MaintainedID")' "$work/in.sarif") \
       <(jq -c '.runs[0].results[] | select(.ruleId == "MaintainedID")' "$work/out.sarif")
check "counts are logged" logged "13 result(s), 8 dropped as accepted"
check "a drop is logged with rule, path:line and reason" \
  logged "dropped  PinnedDependenciesID  ci-aaa/Dockerfile.ci:7  -- base passed as a tag by design"
check "a rule-wide drop is logged" logged "dropped  CodeReviewID  no file associated with this alert:1  -- single maintainer"
check "a keep is logged" logged "kept     PinnedDependenciesID  ci-aaa/Dockerfile.ci:8"
check "BranchProtection is logged as kept" logged "kept     BranchProtectionID"
check "an entry that matched nothing is noted" logged "accepted entry 6 (TokenPermissionsID ^nowhere\$) matched no result"
check "a CRLF line still matches" not_logged "kept     PinnedDependenciesID  crlf.Dockerfile:1"

echo "a location that cannot be resolved is kept"
noloc=$(jq -cn '{ruleId: "PinnedDependenciesID", message: {text: "x"}}')
emptyloc=$(jq -cn '{ruleId: "PinnedDependenciesID", message: {text: "x"}, locations: []}')
twoloc=$(res PinnedDependenciesID ci-aaa/Dockerfile.ci 7 | jq -c '.locations += [.locations[0] | .physicalLocation.region.startLine = 8]')
twook=$(res PinnedDependenciesID ci-aaa/Dockerfile.ci 7 | jq -c '.locations += [.locations[0] | .physicalLocation.artifactLocation.uri = "ci-node9/Dockerfile.ci" | .physicalLocation.region.startLine = 2]')
noline=$(res PinnedDependenciesID ci-aaa/Dockerfile.ci 7 | jq -c 'del(.locations[0].physicalLocation.region)')
sarif \
  "$(res PinnedDependenciesID ci-missing/Dockerfile.ci 1)" \
  "$(res PinnedDependenciesID ci-aaa/Dockerfile.ci 99)" \
  "$(res PinnedDependenciesID ci-aaa/Dockerfile.ci 0)" \
  "$(res PinnedDependenciesID ci-aaa/Dockerfile.ci 2)" \
  "$(res PinnedDependenciesID "sub/ci-aaa/Dockerfile.ci" 7)" \
  "$(res PinnedDependenciesID "$nofile" 1)" \
  "$noloc" "$emptyloc" "$twoloc" "$noline" \
  "$(res CodeReviewID "ci-missing/x" 5)" \
  "$twook" \
  > "$work/in2.sarif"
run "$work/accepted.json" "$work/in2.sarif" "$work/out2.sarif"
check "exits 0" [ "$rc" -eq 0 ]
check "only the rule-wide one and the fully covered two-location one are dropped" \
  [ "$(jq '.runs[0].results | length' "$work/out2.sarif")" -eq 10 ]
check "the rule-wide entry covers an unresolvable location" \
  [ "$(jq '[.runs[0].results[] | select(.ruleId == "CodeReviewID")] | length' "$work/out2.sarif")" -eq 0 ]
check "a result with one uncovered location of two is kept" \
  quiet jq -e '[.runs[0].results[] | select((.locations | length) == 2 and .locations[1].physicalLocation.region.startLine == 8)] | length == 1' "$work/out2.sarif"
check "no location is logged as such" logged "kept     PinnedDependenciesID  (no location)"

echo "a path outside the checkout is never read"
# A path pattern loose enough to match them, so only the path checks stop it.
mkdir -p "$work/repo/ci-zzz" "$work/outside"
printf '%s\n' "$from_line" > "$work/repo/ci-zzz/Dockerfile.ci"
printf '%s\n' "$from_line" > "$work/outside/Dockerfile.ci"
printf '%s\n' '[{"rule": "PinnedDependenciesID", "path": "^.*Dockerfile\\.ci$", "match": "^FROM ", "reason": "loose"}]' > "$work/loose.json"
sarif \
  "$(res PinnedDependenciesID ci-zzz/Dockerfile.ci 1)" \
  "$(res PinnedDependenciesID ci-aaa/../ci-zzz/Dockerfile.ci 1)" \
  "$(res PinnedDependenciesID ../outside/Dockerfile.ci 1)" \
  "$(res PinnedDependenciesID "$work/outside/Dockerfile.ci" 1)" \
  "$(res PinnedDependenciesID "ci-zzz/Dockerfile.ci;id" 1)" \
  > "$work/in5.sarif"
run "$work/loose.json" "$work/in5.sarif" "$work/out5.sarif"
check "exits 0" [ "$rc" -eq 0 ]
check "only the plain relative path is dropped" \
  [ "$(jq '[.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri] | join(" ")' "$work/out5.sarif")" \
    = "\"ci-aaa/../ci-zzz/Dockerfile.ci ../outside/Dockerfile.ci $work/outside/Dockerfile.ci ci-zzz/Dockerfile.ci;id\"" ]

echo "a broken accepted list writes nothing"
bad_list() {
  local name="$1" json="$2" want="$3"
  printf '%s\n' "$json" > "$work/bad.json"
  echo stale > "$work/out3.sarif"
  run "$work/bad.json" "$work/in.sarif" "$work/out3.sarif"
  check "$name: exits 1" [ "$rc" -eq 1 ]
  check "$name: no output, not even the stale one" [ ! -e "$work/out3.sarif" ]
  check "$name: says why" logged "$want"
}
bad_list "unknown key" '[{"rule": "FuzzingID", "reason": "r", "paths": "^x$"}]' 'unknown key "paths"'
bad_list "no reason" '[{"rule": "FuzzingID"}]' 'missing or empty "reason"'
bad_list "empty reason" '[{"rule": "FuzzingID", "reason": ""}]' 'missing or empty "reason"'
bad_list "no rule" '[{"reason": "r"}]' 'missing or empty "rule"'
bad_list "not a rule id" '[{"rule": "Fuzzing", "reason": "r"}]' 'is not a Scorecard rule id'
bad_list "path without match" '[{"rule": "PinnedDependenciesID", "path": "^x$", "reason": "r"}]' '"path" and "match" go together'
bad_list "match without path" '[{"rule": "PinnedDependenciesID", "match": "x", "reason": "r"}]' '"path" and "match" go together'
bad_list "unanchored path" '[{"rule": "PinnedDependenciesID", "path": "Dockerfile", "match": "x", "reason": "r"}]' 'must be anchored'
bad_list "bad regex" '[{"rule": "PinnedDependenciesID", "path": "^(x$", "match": "x", "reason": "r"}]' 'is not a valid regular expression'
bad_list "not an array" '{"rule": "FuzzingID", "reason": "r"}' 'not a JSON array'
bad_list "not an object" '["FuzzingID"]' 'not an object'
bad_list "not JSON" '[{"rule": ' 'is not valid JSON'

echo "a SARIF it does not understand writes nothing"
bad_sarif() {
  local name="$1" json="$2"
  printf '%s\n' "$json" > "$work/bad.sarif"
  echo stale > "$work/out4.sarif"
  run "$work/accepted.json" "$work/bad.sarif" "$work/out4.sarif"
  check "$name: exits 1" [ "$rc" -eq 1 ]
  check "$name: no output" [ ! -e "$work/out4.sarif" ]
}
bad_sarif "not JSON" '{"runs": ['
bad_sarif "no runs" '{"version": "2.1.0"}'
bad_sarif "empty runs" '{"runs": []}'
bad_sarif "no results" '{"runs": [{"tool": {}}]}'
bad_sarif "result without ruleId" '{"runs": [{"results": [{"message": {"text": "x"}}]}]}'
bad_sarif "locations not an array" '{"runs": [{"results": [{"ruleId": "FuzzingID", "locations": {}}]}]}'
run "$work/accepted.json" "$work/nonexistent.sarif" "$work/out4.sarif"
check "missing input: exits 1" [ "$rc" -eq 1 ]

echo "usage"
rc=0; "$script" only-one > /dev/null 2>&1 || rc=$?
check "one operand: exits 2" [ "$rc" -eq 2 ]
rc=0; "$script" --bogus a b > /dev/null 2>&1 || rc=$?
check "unknown option: exits 2" [ "$rc" -eq 2 ]
rc=0; "$script" --accepted "$work/accepted.json" --check > /dev/null 2>&1 || rc=$?
check "--check on a good list: exits 0" [ "$rc" -eq 0 ]
rc=0; "$script" --accepted "$work/bad.json" --check > /dev/null 2>&1 || rc=$?
check "--check on a bad list: exits 1" [ "$rc" -eq 1 ]

# --- The real list against the real tree: every finding Scorecard reports
# --- today, rebuilt from the Dockerfiles, must be dropped -- except the two
# --- the owner has to see -- and an unaccepted line must still be kept.
echo "the real accepted list against this repository"
rc=0; "$script" --check > "$work/log" 2>&1 || rc=$?
check ".github/scorecard-accepted.json is valid" [ "$rc" -eq 0 ]
real=()
for img in $(jq -r '.[].image' "$repo/.github/images.json"); do
  f="$img/Dockerfile.ci"
  n=$(grep -n '^FROM ' "$repo/$f" | cut -d: -f1 || true)
  check "$f has exactly one FROM" [ "$(printf '%s\n' "$n" | grep -c .)" -eq 1 ]
  check "$f's FROM is FROM \${BASE_IMAGE}" grep -qxF "$from_line" "$repo/$f"
  real+=("$(res PinnedDependenciesID "$f" "${n:-0}" 'containerImage not pinned by hash')")
  while IFS=: read -r n _; do
    real+=("$(res PinnedDependenciesID "$f" "$n" 'npmCommand not pinned by hash')")
  done < <(grep -n '^RUN npm install --global "npm@' "$repo/$f" || true)
done
n=$(grep -n '^RUN /opt/az/bin/python3 -m pip install ' "$repo/ci-cloud/Dockerfile.ci" | cut -d: -f1 || true)
check "ci-cloud/Dockerfile.ci still has the azure-cli pip floors" [ -n "$n" ]
real+=("$(res PinnedDependenciesID ci-cloud/Dockerfile.ci "${n:-0}" 'pipCommand not pinned by hash')")
for r in CodeReviewID FuzzingID CIIBestPracticesID BranchProtectionID MaintainedID; do
  real+=("$(res "$r" "$nofile" 1)")
done
# Not accepted: a line of a Dockerfile.ci that is not one of the above.
real+=("$(res PinnedDependenciesID ci-node22/Dockerfile.ci 1 'not an accepted line')")
sarif "${real[@]}" > "$work/real.sarif"
rc=0; "$script" "$work/real.sarif" "$work/real-out.sarif" > "$work/log" 2>&1 || rc=$?
check "exits 0" [ "$rc" -eq 0 ]
check "every ci-node* image's npm pin line was found" \
  [ "$(jq '[.runs[0].results[] | select(.message.text | test("npmCommand"))] | length' "$work/real.sarif")" \
    -eq "$(jq '[.[] | select(.image | test("^ci-node[0-9]+$"))] | length' "$repo/.github/images.json")" ]
check "kept exactly BranchProtection, Maintained and the unaccepted line" \
  diff -u <(printf '%s\n' "BranchProtectionID $nofile:1" "MaintainedID $nofile:1" "PinnedDependenciesID ci-node22/Dockerfile.ci:1") \
          <(kept_ids "$work/real-out.sarif")
check "no accepted entry is unused" not_logged "matched no result"
check "the accepted list never names BranchProtectionID or MaintainedID" \
  quiet jq -e 'all(.[]; .rule != "BranchProtectionID" and .rule != "MaintainedID")' "$repo/.github/scorecard-accepted.json"

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
