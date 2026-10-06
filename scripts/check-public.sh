#!/usr/bin/env bash
# Is a published GHCR reference pullable by anyone, with no credentials at all?
#
#   ./scripts/check-public.sh ghcr.io/<owner>/<image>:<tag>
#   ./scripts/check-public.sh ghcr.io/<owner>/<image>@sha256:<digest>
#   ./scripts/check-public.sh --warn ghcr.io/<owner>/<mirror>:<tag>
#
# Why: a package first published from this public, user-owned repository with
# GITHUB_TOKEN comes out public (observed 2026-10-06, workflow run
# 37528439871 on a throwaway package). GitHub's documentation says new
# packages start private, so this is the safety net that notices if that ever
# stops being true -- or if someone flips a package to private later.
#
# How: exactly what an anonymous `docker pull` does first, with curl and
# nothing else. Ask https://ghcr.io/token for a pull token with NO
# Authorization header, then HEAD the manifest with that token. Never docker,
# never the job's `docker login`, never DOCKER_CONFIG or ~/.docker: a check
# made with the job's own credentials would pass on a private package, which
# is the one thing it must not do. `-q` keeps a ~/.curlrc out of it too.
#
# Exit:
#   0  public: the anonymous token was issued and the manifest answered 200
#   3  not public: the token request was refused (401/403) or the manifest
#      answered 401/403/404 -- a private package, or one that does not exist
#   1  could not check: network failure (HTTP 000), a 5xx, or any other
#      answer -- treated as a failure by callers, never as a pass
#   2  usage
#
# Retries 3 and 1, up to four attempts, waiting 10s, 20s and 40s between them,
# the same shape as scripts/verify-ref.sh: a package created seconds ago may
# not answer anonymously at once. Only the last attempt decides.
# CHECK_PUBLIC_DELAYS overrides the waits (one per retry; "" means a single
# attempt). The offline tests, scripts/test-check-public.sh, use it.
#
# Each request is bounded: 5s to connect, 10s in all (CHECK_PUBLIC_CONNECT_TIMEOUT
# and CHECK_PUBLIC_MAX_TIME override them). An attempt is at most two
# requests, so the worst case -- a registry that accepts the connection and
# then hangs -- is 20s per attempt plus the waits: 150s with the defaults,
# 50s with CHECK_PUBLIC_DELAYS=10. Callers that check many references budget
# for that (build-and-push.yml's mirror job, check-published.sh).
#
# On failure the last line is a GitHub annotation naming the package and its
# settings page -- ::error:: by default, ::warning:: with --warn (for callers
# that report rather than gate).
set -euo pipefail

usage() { echo "usage: check-public.sh [--warn] ghcr.io/OWNER/NAME:TAG | ghcr.io/OWNER/NAME@sha256:DIGEST" >&2; exit 2; }

level=error
if [ "${1:-}" = --warn ]; then level=warning; shift; fi
if [ $# -ne 1 ] || [ -z "$1" ]; then usage; fi
ref="$1"

# ghcr.io/<owner>/<name>[/<more>] then :tag or @sha256:digest. Lowercase
# only: GHCR repository names are.
if [[ "$ref" =~ ^ghcr\.io/([a-z0-9][a-z0-9._-]*)/([a-z0-9][a-z0-9._/-]*)@(sha256:[0-9a-f]{64})$ ]] ||
   [[ "$ref" =~ ^ghcr\.io/([a-z0-9][a-z0-9._-]*)/([a-z0-9][a-z0-9._/-]*):([A-Za-z0-9_][A-Za-z0-9._-]{0,127})$ ]]; then
  owner="${BASH_REMATCH[1]}" pkg="${BASH_REMATCH[2]}" reference="${BASH_REMATCH[3]}"
else
  echo "error: not a ghcr.io tag or digest reference: '$ref'" >&2
  usage
fi
name="$owner/$pkg"
settings="https://github.com/users/$owner/packages/container/${pkg//\//%2F}/settings"

read -r -a delays <<< "${CHECK_PUBLIC_DELAYS-10 20 40}"
for d in ${delays[@]+"${delays[@]}"}; do
  [[ "$d" =~ ^[0-9]+$ ]] || { echo "error: CHECK_PUBLIC_DELAYS must be whole seconds, got '$d'" >&2; exit 2; }
done
attempts=$(( ${#delays[@]} + 1 ))
max_time="${CHECK_PUBLIC_MAX_TIME:-10}" connect_timeout="${CHECK_PUBLIC_CONNECT_TIMEOUT:-5}"
for v in "$max_time" "$connect_timeout"; do
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "error: CHECK_PUBLIC_MAX_TIME and CHECK_PUBLIC_CONNECT_TIMEOUT must be whole seconds above 0, got '$v'" >&2; exit 2; }
done

command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq not found" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

accept='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

# probe -- one anonymous attempt. Sets rc (0|1|3) and why.
probe() {
  local code token
  # No -H, no -u, no --netrc: this request carries no credential at all.
  # No -L on either request: a redirect is not followed, it is an answer
  # this does not expect (could not check).
  code=$(curl -q -sS --connect-timeout "$connect_timeout" --max-time "$max_time" -o "$tmp/token.json" -w '%{http_code}' \
    "https://ghcr.io/token?scope=repository:${name}:pull&service=ghcr.io" 2>"$tmp/curl.err") || true
  case "$code" in
    200) ;;
    401|403) rc=3; why="anonymous token refused (HTTP $code)"; return 0 ;;
    *) rc=1; why="token request failed (HTTP ${code:-000}$(err_suffix))"; return 0 ;;
  esac
  token=$(jq -r '.token // empty' "$tmp/token.json" 2>/dev/null) || token=""
  if [ -z "$token" ]; then
    rc=1; why="token response had no token"; return 0
  fi

  code=$(curl -q -sS --connect-timeout "$connect_timeout" --max-time "$max_time" -I -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $token" -H "Accept: $accept" \
    "https://ghcr.io/v2/${name}/manifests/${reference}" 2>"$tmp/curl.err") || true
  case "$code" in
    200) rc=0; why="anonymous token issued, manifest HTTP 200" ;;
    401|403|404) rc=3; why="anonymous token issued, manifest HTTP $code" ;;
    *) rc=1; why="manifest request failed (HTTP ${code:-000}$(err_suffix))" ;;
  esac
}

err_suffix() {
  [ -s "$tmp/curl.err" ] || return 0
  printf ': %s' "$(tr '\n' ' ' < "$tmp/curl.err" | cut -c1-200)"
}

rc=1 why=""
attempt=0
while [ "$attempt" -lt "$attempts" ]; do
  attempt=$((attempt + 1))
  probe
  echo "check-public: attempt $attempt of $attempts: $ref: $why"
  [ "$rc" -eq 0 ] && break
  if [ "$attempt" -lt "$attempts" ]; then
    wait_s="${delays[$((attempt - 1))]}"
    echo "::warning::attempt $attempt of $attempts to pull $ref anonymously failed ($why); retrying in ${wait_s}s"
    sleep "$wait_s"
  fi
done

n="$attempt attempt"; [ "$attempt" -eq 1 ] || n="${n}s"
case "$rc" in
  0) echo "public: $ref is pullable anonymously (attempt $attempt of $attempts)" ;;
  3) echo "::$level::ghcr.io/$name is not public: $ref cannot be pulled anonymously after $n ($why). Make it public: $settings -> Danger Zone -> Change visibility -> Public" ;;
  *) echo "::$level::could not check whether $ref is pullable anonymously after $n ($why) -- treated as a failure, not a pass" ;;
esac
exit "$rc"
