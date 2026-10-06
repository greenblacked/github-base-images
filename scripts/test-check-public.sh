#!/usr/bin/env bash
# Offline tests for scripts/check-public.sh, the anonymous-pull check that
# runs after every publish. No network, no registry: curl is a fake on PATH
# that answers each call with the next line of a scripted sequence
# ("CODE [BODY]") and records its arguments, and sleep is a fake that only
# records how long it was asked to wait.
#
#   ./scripts/test-check-public.sh       # run by scripts/lint.sh, so CI runs it too
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$here/check-public.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$work/bin"
# The fake curl. Each call takes the first line left in FAKE_RESPONSES:
# "CODE" or "CODE BODY". It writes BODY to the -o file, prints CODE for -w,
# and for 000 fails the way curl does on a refused connection. The call's
# arguments go to FAKE_CURL_LOG, one call per line, each argument followed by
# a tab. An exhausted sequence answers 999, which no case expects.
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\t' "$a"; done >> "$FAKE_CURL_LOG"
echo >> "$FAKE_CURL_LOG"
line=$(head -n1 "$FAKE_RESPONSES")
tail -n +2 "$FAKE_RESPONSES" > "$FAKE_RESPONSES.next"; mv "$FAKE_RESPONSES.next" "$FAKE_RESPONSES"
code="${line%% *}"; body=""
[ "$line" = "$code" ] || body="${line#* }"
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; esac
  shift
done
[ -n "$out" ] && [ "$out" != /dev/null ] && printf '%s' "$body" > "$out"
printf '%s' "${code:-999}"
if [ "$code" = 000 ]; then echo "curl: (7) Failed to connect to ghcr.io port 443" >&2; exit 7; fi
exit 0
EOF
cat > "$work/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SLEEP_LOG"
EOF
chmod +x "$work/bin/curl" "$work/bin/sleep"

# Credentials the script must never use: a docker config in DOCKER_CONFIG and
# one in $HOME/.docker, each with its own recognisable secret.
mkdir -p "$work/dockercfg" "$work/home/.docker"
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "U0VDUkVUX0RPQ0tFUl9DT05GSUc=" > "$work/dockercfg/config.json"
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "U0VDUkVUX0hPTUVfRE9DS0VS" > "$work/home/.docker/config.json"

unset CHECK_PUBLIC_DELAYS
TAG_REF="ghcr.io/o/ci-test:bookworm-v1"
DIGEST="sha256:$(printf 'a%.0s' $(seq 64))"
DIGEST_REF="ghcr.io/o/ci-test@$DIGEST"
TOK='200 {"token":"anon-tok"}'
LINK="https://github.com/users/o/packages/container/ci-test/settings"

# run RESPONSE... -- ARGS... : runs check-public.sh against the fake; sets rc,
# out, and the curl and sleep logs.
run() {
  local responses=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do responses+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  out="$work/out"; calls="$work/calls"; sleeps="$work/sleeps"
  printf '%s\n' ${responses[@]+"${responses[@]}"} > "$work/responses"
  : > "$calls"; : > "$sleeps"
  rc=0
  PATH="$work/bin:$PATH" HOME="$work/home" DOCKER_CONFIG="$work/dockercfg" \
    FAKE_RESPONSES="$work/responses" FAKE_CURL_LOG="$calls" FAKE_SLEEP_LOG="$sleeps" \
    "$script" "$@" > "$out" 2>&1 || rc=$?
}
ncalls()  { wc -l < "$calls" | tr -d ' '; }
call()    { sed -n "${1}p" "$calls"; }
slept()   { paste -sd, "$sleeps"; }
has()     { grep -qF -- "$1" "$out"; }
hasnt()   { ! grep -qF -- "$1" "$out"; }
# args N -- call N's arguments, one per line; allargs -- every call's.
args()    { sed -n "${1}p" "$calls" | tr '\t' '\n'; }
allargs() { tr '\t' '\n' < "$calls"; }

echo "case 1: public on the first try"
run "$TOK" 200 -- "$TAG_REF"
check "exit 0" [ "$rc" -eq 0 ]
check "2 curl calls: token, manifest" [ "$(ncalls)" -eq 2 ]
check "no wait" [ ! -s "$sleeps" ]
check "token request is anonymous, for pull on the right repository" \
  bash -c "sed -n 1p '$calls' | grep -qF 'https://ghcr.io/token?scope=repository:o/ci-test:pull&service=ghcr.io'"
check "manifest HEAD of the tag" bash -c "sed -n 2p '$calls' | grep -qF 'https://ghcr.io/v2/o/ci-test/manifests/bookworm-v1'"
check "  with -I" bash -c "$(declare -f args); calls='$calls'; args 2 | grep -qx -- -I"
check "  carrying the anonymous token" bash -c "sed -n 2p '$calls' | grep -qF 'Authorization: Bearer anon-tok'"
check "  accepting an OCI index" bash -c "sed -n 2p '$calls' | grep -qF 'application/vnd.oci.image.index.v1+json'"
check "  an OCI manifest" bash -c "sed -n 2p '$calls' | grep -qF 'application/vnd.oci.image.manifest.v1+json'"
check "  and a Docker manifest list" bash -c "sed -n 2p '$calls' | grep -qF 'application/vnd.docker.distribution.manifest.list.v2+json'"
check "says public" has "public: $TAG_REF is pullable anonymously (attempt 1 of 4)"
check "no annotation" hasnt "::"

echo "case 2: the token request carries no credential, and no docker config is read"
check "no Authorization header on the token request" bash -c "! grep -qi 'authorization' <<<\"\$(sed -n 1p '$calls')\""
check "no -H at all on the token request" bash -c "$(declare -f args); calls='$calls'; ! args 1 | grep -qxE -- '-H|--header'"
check "no -u/--user/--netrc/-K/--config on any call" bash -c "$(declare -f allargs); calls='$calls'; ! allargs | grep -qxE -- '-u|--user|-n|--netrc|--netrc-file|-K|--config'"
check "every call starts with -q (no ~/.curlrc)" bash -c "[ \"\$(cut -f1 '$calls' | sort -u)\" = '-q' ]"
check "the DOCKER_CONFIG secret is in no call" bash -c "! grep -qF 'U0VDUkVUX0RPQ0tFUl9DT05GSUc=' '$calls'"
check "the ~/.docker secret is in no call" bash -c "! grep -qF 'U0VDUkVUX0hPTUVfRE9DS0VS' '$calls'"
check "the script never names DOCKER_CONFIG, ~/.docker or docker login outside comments" \
  bash -c "! grep -v '^[[:space:]]*#' '$script' | grep -qE 'DOCKER_CONFIG|/\.docker|docker (login|pull)|config\.json'"

echo "case 3: 403 then public -> passes after one retry"
run 403 "$TOK" 200 -- "$TAG_REF"
check "exit 0" [ "$rc" -eq 0 ]
check "3 curl calls" [ "$(ncalls)" -eq 3 ]
check "waited 10s once" [ "$(slept)" = "10" ]
check "the failed attempt is a warning" has "::warning::attempt 1 of 4 to pull $TAG_REF anonymously failed (anonymous token refused (HTTP 403)); retrying in 10s"
check "says public on attempt 2" has "(attempt 2 of 4)"
check "no error" hasnt "::error::"
check "no token request ever had an Authorization header" bash -c "! grep -F 'https://ghcr.io/token?' '$calls' | grep -qi authorization"

echo "case 4: 403 x4 -> exit 3, with the settings link"
run 403 403 403 403 -- "$TAG_REF"
check "exit 3" [ "$rc" -eq 3 ]
check "4 curl calls (token only)" [ "$(ncalls)" -eq 4 ]
check "waited 10s, 20s, 40s -- not after the last" [ "$(slept)" = "10,20,40" ]
check "the error names the package, the ref and the attempts" \
  has "::error::ghcr.io/o/ci-test is not public: $TAG_REF cannot be pulled anonymously after 4 attempts (anonymous token refused (HTTP 403))."
check "  and gives the settings link and the fix" has "Make it public: $LINK -> Danger Zone -> Change visibility -> Public"
check "not reported as public" bash -c "! grep -q '^public:' '$out'"

echo "case 5: 000 / 502 -> retried, ends as could-not-check (1)"
run 000 502 000 502 -- "$TAG_REF"
check "exit 1" [ "$rc" -eq 1 ]
check "4 attempts" [ "$(ncalls)" -eq 4 ]
check "waited 10s, 20s, 40s" [ "$(slept)" = "10,20,40" ]
check "the network failure is logged with curl's message" has "token request failed (HTTP 000: curl: (7) Failed to connect"
check "the could-not-check error" has "::error::could not check whether $TAG_REF is pullable anonymously after 4 attempts (token request failed (HTTP 502)) -- treated as a failure, not a pass"
check "no settings link: nothing says it is private" hasnt "Change visibility"

echo "case 6: token issued, manifest 5xx then 200 -> passes"
run "$TOK" 503 "$TOK" 200 -- "$TAG_REF"
check "exit 0" [ "$rc" -eq 0 ]
check "4 curl calls" [ "$(ncalls)" -eq 4 ]
check "the 503 was a retried warning" has "manifest request failed (HTTP 503)); retrying in 10s"

echo "case 7: token issued but the manifest answers 404/401/403 -> not public"
run "$TOK" 404 "$TOK" 401 "$TOK" 403 "$TOK" 404 -- "$TAG_REF"
check "exit 3" [ "$rc" -eq 3 ]
check "8 curl calls" [ "$(ncalls)" -eq 8 ]
check "the error says the manifest answered 404" has "(anonymous token issued, manifest HTTP 404)"

echo "case 8: only the last attempt decides -- 403, 000, 403, 502 ends as 1"
run 403 000 403 502 -- "$TAG_REF"
check "exit 1" [ "$rc" -eq 1 ]
run 502 000 502 403 -- "$TAG_REF"
check "and 502, 000, 502, 403 ends as 3" [ "$rc" -eq 3 ]

echo "case 9: a 200 token response with no token -> could not check"
run '200 {}' '200 {}' '200 {}' '200 {}' -- "$TAG_REF"
check "exit 1" [ "$rc" -eq 1 ]
check "no manifest request without a token" [ -z "$(grep -F '/v2/' "$calls" || true)" ]
check "says why" has "token response had no token"

echo "case 10: a digest reference"
run "$TOK" 200 -- "$DIGEST_REF"
check "exit 0" [ "$rc" -eq 0 ]
check "HEADs the digest" bash -c "sed -n 2p '$calls' | grep -qF 'https://ghcr.io/v2/o/ci-test/manifests/$DIGEST'"

echo "case 11: --warn reports with a warning, same exit codes"
run 403 403 403 403 -- --warn "ghcr.io/o/mirror-node:22-bookworm-slim"
check "exit 3" [ "$rc" -eq 3 ]
check "a warning with the link" has "::warning::ghcr.io/o/mirror-node is not public:"
check "  the mirror's own settings page" has "https://github.com/users/o/packages/container/mirror-node/settings"
check "no error annotation" hasnt "::error::"

echo "case 12: a nested package name is encoded in the settings link"
CHECK_PUBLIC_DELAYS="" run 403 -- "ghcr.io/o/team/tool:v1"
check "token scope keeps the slash" bash -c "grep -qF 'scope=repository:o/team/tool:pull' '$calls'"
check "link encodes it" has "https://github.com/users/o/packages/container/team%2Ftool/settings"

echo "case 13: CHECK_PUBLIC_DELAYS"
CHECK_PUBLIC_DELAYS="0 0" run 403 403 403 403 -- "$TAG_REF"
check "two waits -> 3 attempts" [ "$rc:$(ncalls):$(slept)" = "3:3:0,0" ]
CHECK_PUBLIC_DELAYS="" run 403 "$TOK" 200 -- "$TAG_REF"
check "empty -> a single attempt" [ "$rc:$(ncalls)" = "3:1" ]
check "  error says 1 attempt" has "after 1 attempt ("
CHECK_PUBLIC_DELAYS="10 soon" run "$TOK" 200 -- "$TAG_REF"
check "a non-numeric delay is a usage error" [ "$rc:$(ncalls)" = "2:0" ]

echo "case 14: usage -- exit 2, nothing requested"
for bad_ref in "" "docker.io/o/ci-test:v1" "ghcr.io/O/ci-test:v1" "ghcr.io/o/ci-test" "ghcr.io/o/ci-test@sha256:abc" "ghcr.io/ci-test:v1"; do
  run "$TOK" 200 -- "$bad_ref"
  check "rejects '${bad_ref}'" [ "$rc:$(ncalls)" = "2:0" ]
done
run "$TOK" 200 --
check "no argument" [ "$rc:$(ncalls)" = "2:0" ]
run "$TOK" 200 -- "$TAG_REF" extra
check "two arguments" [ "$rc:$(ncalls)" = "2:0" ]

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
