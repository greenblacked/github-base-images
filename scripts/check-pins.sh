#!/usr/bin/env bash
# Compare every hand-pinned tool version in this repository against the version
# its vendor currently ships, and report the ones that have drifted.
#
# These pins are the one corner of the supply chain nothing watches. Dependabot
# reads each Dockerfile's `ARG BASE_IMAGE` and nothing else, so every tool below
# moves only when a human moves it -- and a manual audit found six of them
# behind at once, one of them (Rust, since fixed by other means) twelve releases
# back. This script is that audit, automated.
#
#   ./scripts/check-pins.sh                 # human-readable table
#   ./scripts/check-pins.sh --format json   # machine-readable, for the workflow
#   ./scripts/check-pins.sh --only trivy    # one tool, for a quick check
#
# Exit codes:
#   0  every pin is current
#   1  no drift, but a vendor endpoint was unreachable -- a broken checker
#   2  bad usage
#   3  drift found -- a normal, expected outcome, not an error
#
# 3 outranks 1: drift is actionable and must still reach the tracking issue even
# when one resolver is broken. Unresolved tools appear in the report with
# state "unresolved" so they are never silently dropped.
#
# Read-only: it fetches version metadata and never writes to the repository or
# to any vendor. The caller (the pin-drift workflow) is what opens an issue.
set -euo pipefail

readonly EXIT_DRIFT=3
readonly TIMEOUT=25
readonly RETRIES=2

format=table
only=""
log_level=info

usage() {
  cat <<'EOF'
usage: check-pins.sh [--format table|json] [--only TOOL] [--quiet]

  --format   output shape on stdout (default: table)
  --only     check a single tool by name, e.g. --only kubectl
  --quiet    suppress progress logging on stderr

Exit: 0 current, 1 runtime failure, 2 usage, 3 drift found.
EOF
}

# --- logging: stderr only, so stdout stays a clean, pipeable report ----------
log() {
  local level="$1"; shift
  [ "$log_level" = quiet ] && [ "$level" = info ] && return 0
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}

# --- argument parsing, before any network call ------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --format) [ $# -ge 2 ] || { echo "error: --format needs a value" >&2; usage >&2; exit 2; }
              format="$2"; shift 2 ;;
    --only)   [ $# -ge 2 ] || { echo "error: --only needs a value" >&2; usage >&2; exit 2; }
              only="$2"; shift 2 ;;
    --quiet)  log_level=quiet; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$format" in
  table|json) ;;
  *) echo "error: --format must be 'table' or 'json', got '$format'" >&2; exit 2 ;;
esac

for cmd in curl jq sort grep sed; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root" || { echo "error: cannot enter repo root" >&2; exit 1; }

tmp=$(mktemp -d)
# Trap rather than a tidy-up at the end of the happy path: an early exit from a
# failed fetch must not leave the directory behind. Inlined rather than calling
# a cleanup function, which shellcheck flags as uninvoked (SC2329) because it
# cannot see through the trap.
trap 'rm -rf "$tmp"' EXIT INT TERM

# --- the registry -----------------------------------------------------------
# name | file holding the pin | ARG (or env) key | resolver | resolver argument
#
# The pinned value is read from the file rather than duplicated here, so this
# script cannot disagree with what actually builds.
readonly PINS='
terraform  | ci-tools/Dockerfile.ci               | TERRAFORM_VERSION  | hashicorp | terraform
kubectl    | ci-tools/Dockerfile.ci               | KUBECTL_VERSION    | k8s       | -
awscli     | ci-tools/Dockerfile.ci               | AWSCLI_VERSION     | githubtag | aws/aws-cli
docker     | ci-tools/Dockerfile.ci               | DOCKER_VERSION     | dockerstatic | -
gcloud     | ci-cloud/Dockerfile.ci               | GCLOUD_VERSION     | gcs       | -
playwright | ci-node22/Dockerfile.ci              | PLAYWRIGHT_VERSION | npm       | playwright
composer   | ci-php84/Dockerfile.ci               | COMPOSER_VERSION   | github    | composer/composer
trivy      | ci-security/Dockerfile.ci            | TRIVY_VERSION      | github    | aquasecurity/trivy
syft       | ci-security/Dockerfile.ci            | SYFT_VERSION       | github    | anchore/syft
grype      | ci-security/Dockerfile.ci            | GRYPE_VERSION      | github    | anchore/grype
cosign     | ci-security/Dockerfile.ci            | COSIGN_VERSION     | github    | sigstore/cosign
gitleaks   | ci-security/Dockerfile.ci            | GITLEAKS_VERSION   | github    | gitleaks/gitleaks
migrate    | ci-db/Dockerfile.ci                  | MIGRATE_VERSION    | github    | golang-migrate/migrate
'

fetch() {
  # Every call bounded: without --max-time a hung vendor endpoint would stall
  # the scheduled job until the job timeout and report as "timed out" rather
  # than naming the vendor that hung.
  curl -fsSL --retry "$RETRIES" --retry-all-errors --max-time "$TIMEOUT" "$@"
}

# --- resolvers: each prints the vendor's current version, bare (no leading v) -
resolve_github() {
  local repo="$1" auth=()
  # GITHUB_TOKEN is read from the environment, never taken as an argument, and
  # never echoed. Unauthenticated calls work but are rate limited to 60/hour,
  # which 9 tools would exhaust quickly on a shared runner.
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  fetch "${auth[@]}" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repo/releases/latest" \
    | jq -r '.tag_name // empty' | sed 's/^v//'
}

# aws/aws-cli publishes git TAGS but no GitHub Releases, so releases/latest
# 404s there. Read the tag list instead and take the highest semver -- tags come
# back newest-first rather than sorted, so `sort -V` does the ordering.
resolve_githubtag() {
  local repo="$1" auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  fetch "${auth[@]}" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repo/tags?per_page=100" \
    | jq -r '.[].name // empty' | sed 's/^v//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}

resolve_k8s() { fetch https://dl.k8s.io/release/stable.txt | sed 's/^v//'; }

resolve_hashicorp() {
  fetch "https://releases.hashicorp.com/$1/" \
    | grep -oE "$1"'_[0-9]+\.[0-9]+\.[0-9]+<' | sed "s/$1"'_//;s/<//' \
    | sort -V | tail -1
}

resolve_dockerstatic() {
  fetch https://download.docker.com/linux/static/stable/x86_64/ \
    | grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' \
    | sed 's/docker-//;s/\.tgz//' | sort -V | tail -1
}

resolve_npm() { fetch "https://registry.npmjs.org/$1" | jq -r '."dist-tags".latest // empty'; }

resolve_gcs() {
  fetch 'https://storage.googleapis.com/cloud-sdk-release?prefix=google-cloud-cli-&max-keys=8000' \
    | grep -oE '<Key>google-cloud-cli-[0-9]+\.[0-9]+\.[0-9]+-linux-x86_64\.tar\.gz</Key>' \
    | sed 's/.*google-cloud-cli-//;s/-linux-x86_64.*//' | sort -V | tail -1
}

current_pin() {
  local file="$1" key="$2" value
  value=$(grep -m1 -E "^(ARG )?${key}=" "$file" 2>/dev/null | sed "s/^ARG //;s/^${key}=//" || true)
  printf '%s' "$value"
}

# --- main loop --------------------------------------------------------------
drift=0; failed=0; checked=0
: > "$tmp/rows.jsonl"

while IFS='|' read -r name file key resolver arg; do
  name=$(printf '%s' "$name" | tr -d ' '); [ -n "$name" ] || continue
  file=$(printf '%s' "$file" | tr -d ' ')
  key=$(printf '%s' "$key" | tr -d ' ')
  resolver=$(printf '%s' "$resolver" | tr -d ' ')
  arg=$(printf '%s' "$arg" | tr -d ' ')

  [ -n "$only" ] && [ "$only" != "$name" ] && continue
  checked=$((checked + 1))

  if [ ! -f "$file" ]; then
    log error "$name: pinned file $file does not exist (renamed image?)"
    failed=$((failed + 1)); continue
  fi

  pinned=$(current_pin "$file" "$key")
  if [ -z "$pinned" ]; then
    log error "$name: no $key found in $file"
    failed=$((failed + 1)); continue
  fi

  log info "checking $name (pinned $pinned)"
  latest=""
  case "$resolver" in
    github)       latest=$(resolve_github "$arg" || true) ;;
    githubtag)    latest=$(resolve_githubtag "$arg" || true) ;;
    k8s)          latest=$(resolve_k8s || true) ;;
    hashicorp)    latest=$(resolve_hashicorp "$arg" || true) ;;
    dockerstatic) latest=$(resolve_dockerstatic || true) ;;
    npm)          latest=$(resolve_npm "$arg" || true) ;;
    gcs)          latest=$(resolve_gcs || true) ;;
    *) log error "$name: unknown resolver '$resolver'"; failed=$((failed + 1)); continue ;;
  esac

  if [ -z "$latest" ]; then
    # Deliberately not fatal for the whole run: one unreachable vendor should
    # not hide drift in the other twelve. Counted, reported, and reflected in
    # the exit code.
    log error "$name: could not resolve current version from vendor"
    failed=$((failed + 1))
    jq -nc --arg tool "$name" --arg pinned "$pinned" --arg file "$file" \
           --arg key "$key" \
      '{tool:$tool, pinned:$pinned, latest:null, file:$file, key:$key, state:"unresolved"}' \
      >> "$tmp/rows.jsonl"
    continue
  fi

  if [ "$pinned" = "$latest" ]; then
    state=current
  elif [ "$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1)" = "$pinned" ]; then
    # Pinned is NEWER than what the vendor advertises as latest -- a yanked
    # release, or a resolver reading the wrong channel. Worth surfacing.
    state=ahead
  else
    state=behind
    drift=$((drift + 1))
  fi

  jq -nc --arg tool "$name" --arg pinned "$pinned" --arg latest "$latest" \
         --arg file "$file" --arg key "$key" --arg state "$state" \
    '{tool:$tool, pinned:$pinned, latest:$latest, file:$file, key:$key, state:$state}' \
    >> "$tmp/rows.jsonl"
done <<< "$PINS"

if [ "$checked" -eq 0 ]; then
  echo "error: no tool matched --only '$only'" >&2
  exit 2
fi

# --- report on stdout -------------------------------------------------------
if [ "$format" = json ]; then
  jq -s --argjson drift "$drift" --argjson failed "$failed" \
    '{drift:$drift, failed:$failed, tools:.}' "$tmp/rows.jsonl"
else
  printf '%-12s %-12s %-12s %s\n' TOOL PINNED LATEST STATE
  jq -r '[.tool,.pinned,.latest,.state] | @tsv' "$tmp/rows.jsonl" \
    | while IFS=$'\t' read -r t p l s; do printf '%-12s %-12s %-12s %s\n' "$t" "$p" "$l" "$s"; done
  echo
  printf 'checked=%d behind=%d unresolved=%d\n' "$checked" "$drift" "$failed"
fi

[ "$failed" -gt 0 ] && log error "$failed tool(s) could not be resolved"
# Drift takes precedence over an unresolved vendor: drift is actionable and must
# still reach the tracking issue even if one resolver is broken. A run with no
# drift but a failed resolver is a broken checker, and goes red.
[ "$drift" -gt 0 ] && { log info "$drift pin(s) behind"; exit "$EXIT_DRIFT"; }
[ "$failed" -gt 0 ] && exit 1
log info "all $checked pins current"
exit 0
