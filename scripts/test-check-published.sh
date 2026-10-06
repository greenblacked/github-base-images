#!/usr/bin/env bash
# Offline tests for the anonymous-pull part of scripts/check-published.sh,
# the published-image audit: which images it checks anonymously, how a result
# counts, and the time budget that keeps a hanging registry inside the
# workflow's timeout. No network: docker, cosign and curl are fakes on PATH,
# and scripts/check-public.sh runs for real against the fake curl. Every
# image in .github/images.json is audited, as in CI.
#
#   ./scripts/test-check-published.sh       # run by scripts/lint.sh, so CI runs it too
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$here/check-published.sh"
n_images=$(jq length "$here/../.github/images.json")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$work/bin"
# docker buildx imagetools inspect: a healthy, fresh, attested index -- or,
# for the image named in FAKE_MISSING, the error GHCR gives for no package.
cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
ref="${*: -1}"
if [ -n "${FAKE_MISSING:-}" ] && [[ "$ref" == *"/$FAKE_MISSING:"* || "$ref" == *"/$FAKE_MISSING@"* ]]; then
  echo "ERROR: ghcr.io/x: not found: 404 Not Found" >&2; exit 1
fi
case "$*" in
  *SBOM*|*Provenance*) echo '{"linux/amd64":{"x":1}}' ;;
  *.Image*) echo "{\"linux/amd64\":{\"created\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" ;;
  *) echo "Name: $ref"; echo "Digest: sha256:$(printf 'b%.0s' $(seq 64))" ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/cosign"
# curl: logs the URL; the token request for FAKE_PRIVATE is refused, for
# FAKE_DOWN it cannot connect; everything else is public. FAKE_SLOW makes
# every call take that many (real) seconds.
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"; out=""
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
[ -n "${FAKE_SLOW:-}" ] && sleep "$FAKE_SLOW"
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
case "$url" in
  *"repository:o/${FAKE_PRIVATE:-none}:pull"*) printf 403 ;;
  *"repository:o/${FAKE_DOWN:-none}:pull"*) printf 000; echo "curl: (28) Connection timed out" >&2; exit 28 ;;
  *token*) printf '{"token":"t"}' > "$out"; printf 200 ;;
  *) printf 200 ;;
esac
EOF
chmod +x "$work/bin/"*

# run [VAR=value...] -- ARGS: runs the audit in JSON form; sets rc, report, calls.
run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  report="$work/report.json"; calls="$work/calls"; : > "$calls"
  rc=0
  env -u GITHUB_REPOSITORY -u CHECK_PUBLIC_BUDGET -u CHECK_PUBLIC_DELAYS \
    PATH="$work/bin:$PATH" OWNER=o REPO_SLUG=o/r CHECK_PUBLIC_DELAYS="" FAKE_CURL_LOG="$calls" \
    ${envs[@]+"${envs[@]}"} "$script" --quiet --format json "$@" > "$report" 2>"$work/err" || rc=$?
}
row()   { jq -r --arg i "$1" ".images[] | select(.image == \$i) | .$2" "$report"; }
count() { jq -r "[.images[] | select($1)] | length" "$report"; }
token_calls_for() { grep -c "repository:o/$1:pull" "$calls" || true; }

echo "case 1: every image public -> exit 0, each checked anonymously once"
run --
check "exit 0" [ "$rc" -eq 0 ]
check "all $n_images rows public_state=ok" [ "$(count '.public_state == "ok"')" -eq "$n_images" ]
check "one token request per image" [ "$(grep -c '/token?' "$calls")" -eq "$n_images" ]
check "  for the image:version a consumer pulls" grep -qF "https://ghcr.io/v2/o/ci-node22/manifests/bookworm-v1" "$calls"

echo "case 2: one package private -> an issue, exit 3, with the fix"
run FAKE_PRIVATE=ci-node22 --
check "exit 3" [ "$rc" -eq 3 ]
check "ci-node22 public_state=private" [ "$(row ci-node22 public_state)" = private ]
check "  status issue" [ "$(row ci-node22 status)" = issue ]
check "  detail names the settings page" bash -c "jq -r '.images[] | select(.image==\"ci-node22\") | .public_detail' '$report' | grep -qF 'https://github.com/users/o/packages/container/ci-node22/settings -> Danger Zone -> Change visibility -> Public'"
check "the others healthy" [ "$(count '.status == "healthy"')" -eq $((n_images - 1)) ]
check "issues=1 failed=0" [ "$(jq -c '[.issues,.failed]' "$report")" = "[1,0]" ]

echo "case 3: a package that does not exist -> no anonymous check, no 'make it public'"
run FAKE_MISSING=ci-node22 --
check "exit 3 (missing is an issue)" [ "$rc" -eq 3 ]
check "pull_state=missing" [ "$(row ci-node22 pull_state)" = missing ]
check "public_state=skipped" [ "$(row ci-node22 public_state)" = skipped ]
check "  says why" [ "$(row ci-node22 public_detail)" = "not checked: the package was not found" ]
check "no anonymous request for it" [ "$(token_calls_for ci-node22)" -eq 0 ]
check "the rest still checked" [ "$(grep -c '/token?' "$calls")" -eq $((n_images - 1)) ]
check "no 'Change visibility' anywhere in the report" bash -c "! grep -q 'Change visibility' '$report'"

echo "case 4: could not check -> unknown, a checker error (exit 1), not a pass"
run FAKE_DOWN=ci-go --
check "exit 1" [ "$rc" -eq 1 ]
check "ci-go public_state=unknown" [ "$(row ci-go public_state)" = unknown ]
check "  status error" [ "$(row ci-go status)" = error ]
check "issues=0 failed=1" [ "$(jq -c '[.issues,.failed]' "$report")" = "[0,1]" ]

echo "case 5: the time budget -- once spent, no new anonymous check starts"
run CHECK_PUBLIC_BUDGET=0 --
check "budget 0: no anonymous request at all" [ ! -s "$calls" ]
check "  every row unknown" [ "$(count '.public_state == "unknown"')" -eq "$n_images" ]
check "  saying the budget was used up" [ "$(row ci-node22 public_detail)" = "not checked: the anonymous checks used up their 0s budget (the registry answered slowly or not at all)" ]
check "  exit 1: a checker error, never a pass" [ "$rc" -eq 1 ]
start=$SECONDS
run CHECK_PUBLIC_BUDGET=1 FAKE_SLOW=1 --
took=$((SECONDS - start))
check "budget 1s, 2s per check: exactly one image checked" [ "$(count '.public_state == "ok"')" -eq 1 ]
check "  two requests made, no more" [ "$(wc -l < "$calls" | tr -d ' ')" -eq 2 ]
check "  the rest unknown" [ "$(count '.public_state == "unknown"')" -eq $((n_images - 1)) ]
check "  exit 1" [ "$rc" -eq 1 ]
check "  and it stopped early (took ${took}s)" [ "$took" -lt 10 ]
run FAKE_PRIVATE=ci-node22 CHECK_PUBLIC_BUDGET=0 --
check "an unchecked private package is unknown, not private (exit 1)" [ "$rc:$(row ci-node22 public_state)" = "1:unknown" ]
run CHECK_PUBLIC_BUDGET=soon --
check "a non-numeric budget is a usage error" [ "$rc" -eq 2 ]

echo "case 6: --ref skips the anonymous check (build-image.yml runs it as its own step)"
run FAKE_PRIVATE=ci-node22 -- --ref "ghcr.io/o/ci-node22@sha256:$(printf 'b%.0s' $(seq 64))"
check "exit 0" [ "$rc" -eq 0 ]
check "public_state=skipped" [ "$(row ci-node22 public_state)" = skipped ]
check "no anonymous request" [ ! -s "$calls" ]

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
