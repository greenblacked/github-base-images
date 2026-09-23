#!/usr/bin/env bash
# Audit what is actually live in the registry, as opposed to what the build
# pipeline believes it published.
#
# Every gate in build-image.yml runs BEFORE the push -- the vulnerability
# scan, the smoke test, the secret scan all inspect an image sitting in the
# local daemon. Nothing afterwards re-checks the artifact a consumer actually
# pulls from ghcr.io. A registry-side mutation, a package flipped to private,
# a signature whose identity silently drifted (a workflow rename, a ref that
# is no longer `main`) -- none of that would fail a build, because none of it
# happens during one. This script is the other half: it re-derives, from the
# published artifact alone, the same facts the build already claimed were
# true the moment it pushed.
#
# Assumes docker buildx, cosign, jq and gh are already on PATH -- the calling
# workflow installs them. Same division of labour as check-pins.sh, which
# assumes curl and jq are already there.
#
#   ./scripts/check-published.sh                 # human-readable table
#   ./scripts/check-published.sh --format json   # machine-readable, for the workflow
#
# Exit codes:
#   0  every image is healthy, current and (if checked) no orphan package
#   1  a script-level failure -- a broken checker, not a broken registry
#   2  bad usage
#   3  one or more images unhealthy or stale, or an orphan package found --
#      a normal, expected outcome, not an error
set -euo pipefail

readonly EXIT_ISSUES=3
readonly COSIGN_ISSUER='https://token.actions.githubusercontent.com'
# A weekly rebuild (build-and-push.yml's own cron) plus enough margin that one
# missed or delayed run does not itself trip this. Two missed rebuilds should.
readonly MAX_AGE_DAYS=10

format=table
log_level=info

usage() {
  cat <<'EOF'
usage: check-published.sh [--format table|json] [--quiet]

  --format   output shape on stdout (default: table)
  --quiet    suppress progress logging on stderr

Reads:
  OWNER            GHCR namespace to audit (default: repository owner from
                    GITHUB_REPOSITORY, or "greenblacked" if unset)
  REPO_SLUG         owner/repo of the signing workflow's identity, used to
                    build the cosign --certificate-identity-regexp (default:
                    GITHUB_REPOSITORY, or "greenblacked/github-base-images")

Exit: 0 clean, 1 script failure, 2 usage, 3 issues found.
EOF
}

log() {
  local level="$1"; shift
  [ "$log_level" = quiet ] && [ "$level" = info ] && return 0
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --format) [ $# -ge 2 ] || { echo "error: --format needs a value" >&2; usage >&2; exit 2; }
              format="$2"; shift 2 ;;
    --quiet)  log_level=quiet; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$format" in
  table|json) ;;
  *) echo "error: --format must be 'table' or 'json', got '$format'" >&2; exit 2 ;;
esac

for cmd in docker cosign jq gh date awk; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root" || { echo "error: cannot enter repo root" >&2; exit 1; }

owner="${OWNER:-${GITHUB_REPOSITORY%%/*}}"
owner="${owner:-greenblacked}"
repo_slug="${REPO_SLUG:-${GITHUB_REPOSITORY:-greenblacked/github-base-images}}"

# The identity a signature is expected to carry. Signing happens inside
# build-image.yml (the REUSABLE workflow), not build-and-push.yml (the
# caller) -- Fulcio binds the certificate to whichever workflow file the
# signing job actually runs, so the caller's name never appears here. Only
# `.` needs escaping; owner/repo characters are regex-safe.
identity_regexp="^https://github\\.com/${repo_slug//./\\.}/\\.github/workflows/build-image\\.yml@refs/heads/main\$"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

: > "$tmp/rows.jsonl"
issues=0

# --- per-image checks --------------------------------------------------------
#
# check_pull sets: pull_state (ok|private|missing|error), digest, inspect_text
check_pull() {
  local ref="$1"
  if inspect_text=$(docker buildx imagetools inspect "$ref" 2>"$tmp/pull_err.txt"); then
    pull_state=ok
    pull_detail=""
    digest=$(awk '/^Digest:/ {print $2; exit}' <<<"$inspect_text")
  else
    local err; err=$(cat "$tmp/pull_err.txt")
    case "$err" in
      *401*|*[Uu]nauthorized*|*403*|*denied*|*[Ff]orbidden*)
        # The single most useful thing this check can surface: several
        # packages here are known to be private, and that is a deliberate,
        # unremarkable state -- distinct from one that is simply gone.
        pull_state=private ;;
      *404*|*"not found"*|*"manifest unknown"*|*"name unknown"*)
        pull_state=missing ;;
      *)
        pull_state=error ;;
    esac
    digest=""
    pull_detail=$(tr '\n' ' ' <<<"$err" | cut -c1-300)
  fi
}

# verify_signature sets: sig_state (ok|fail|skipped), sig_identity
verify_signature() {
  local digest_ref="$1" strict_out diag_out
  if strict_out=$(cosign verify \
        --certificate-oidc-issuer "$COSIGN_ISSUER" \
        --certificate-identity-regexp "$identity_regexp" \
        --output json "$digest_ref" 2>"$tmp/verify_err.txt"); then
    sig_state=ok
    sig_identity=$(jq -r '.[0].optional.Subject // "unknown"' <<<"$strict_out" 2>/dev/null || echo unknown)
  else
    sig_state=fail
    # The strict call above only ever says pass/fail -- a mismatched identity
    # is indistinguishable from no signature at all. Re-run with the same
    # issuer but no identity constraint purely to learn what identity the
    # signature actually carries, so a renamed workflow or a wrong ref shows
    # up as a diagnosis instead of a bare failure.
    if diag_out=$(cosign verify \
          --certificate-oidc-issuer "$COSIGN_ISSUER" \
          --certificate-identity-regexp '.*' \
          --output json "$digest_ref" 2>>"$tmp/verify_err.txt"); then
      sig_identity=$(jq -r '.[0].optional.Subject // "unknown"' <<<"$diag_out" 2>/dev/null || echo unknown)
    else
      sig_identity="none: $(tr '\n' ' ' <"$tmp/verify_err.txt" | cut -c1-300)"
    fi
  fi
}

# attestations sets: has_sbom, has_provenance (true|false)
check_attestations() {
  local digest_ref="$1" sbom_json provenance_json
  sbom_json=$(docker buildx imagetools inspect --format '{{json .SBOM}}' "$digest_ref" 2>/dev/null || true)
  provenance_json=$(docker buildx imagetools inspect --format '{{json .Provenance}}' "$digest_ref" 2>/dev/null || true)
  has_sbom=false; has_provenance=false
  # Not a bare `&&` chain: under `set -e`, a chain ending in an assignment
  # that never runs (because an earlier test failed) makes this function's
  # own return status non-zero, which aborts the script the moment it is
  # called as a plain statement -- an `if` always returns zero when its
  # condition is false, so it is the only safe shape here.
  if [ -n "$sbom_json" ] && [ "$sbom_json" != "null" ] && [ "$sbom_json" != "{}" ]; then
    has_sbom=true
  fi
  if [ -n "$provenance_json" ] && [ "$provenance_json" != "null" ] && [ "$provenance_json" != "{}" ]; then
    has_provenance=true
  fi
}

# freshness sets: created (RFC3339 or empty), age_days (int or empty)
check_freshness() {
  local digest_ref="$1" image_json
  image_json=$(docker buildx imagetools inspect --format '{{json .Image}}' "$digest_ref" 2>/dev/null || true)
  created=""
  if [ -n "$image_json" ] && [ "$image_json" != "null" ]; then
    # Multi-platform images key this by platform; single-platform ones do
    # not. Try linux/amd64 first, then fall back to whatever the first entry
    # is, so this does not depend on which shape buildx happens to return.
    created=$(jq -r '
        if has("linux/amd64") then .["linux/amd64"].created
        elif has("created") then .created
        else (to_entries[0].value.created // empty)
        end // empty' <<<"$image_json" 2>/dev/null || true)
  fi
  age_days=""
  if [ -n "$created" ]; then
    local created_epoch now_epoch
    created_epoch=$(date -u -d "$created" +%s 2>/dev/null || true)
    if [ -n "$created_epoch" ]; then
      now_epoch=$(date -u +%s)
      age_days=$(( (now_epoch - created_epoch) / 86400 ))
    fi
  fi
}

audit_image() {
  local image="$1" version="$2" ref digest_ref
  ref="ghcr.io/${owner}/${image}:${version}"

  log info "auditing $ref"
  check_pull "$ref"

  sig_state=skipped; sig_identity=""
  has_sbom=false; has_provenance=false
  created=""; age_days=""

  if [ "$pull_state" = ok ]; then
    digest_ref="ghcr.io/${owner}/${image}@${digest}"
    verify_signature "$digest_ref"
    check_attestations "$digest_ref"
    check_freshness "$digest_ref"
  fi

  local stale=false
  if [ -n "$age_days" ] && [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
    stale=true
  fi

  local healthy=true
  [ "$pull_state" = ok ] || healthy=false
  [ "$sig_state" = ok ] || healthy=false
  { [ "$has_sbom" = true ] && [ "$has_provenance" = true ]; } || healthy=false
  [ "$stale" = false ] || healthy=false

  if [ "$healthy" = false ]; then
    issues=$((issues + 1))
    log info "$ref: unhealthy (pull=$pull_state sig=$sig_state sbom=$has_sbom provenance=$has_provenance stale=$stale)"
  fi

  jq -nc \
    --arg image "$image" --arg version "$version" --arg ref "$ref" \
    --arg pull_state "$pull_state" --arg pull_detail "${pull_detail:-}" \
    --arg digest "${digest:-}" \
    --arg sig_state "$sig_state" --arg sig_identity "$sig_identity" \
    --argjson has_sbom "$has_sbom" --argjson has_provenance "$has_provenance" \
    --arg created "$created" \
    --argjson age_days "${age_days:-null}" --argjson stale "$stale" \
    --argjson healthy "$healthy" \
    '{image:$image, version:$version, ref:$ref, pull_state:$pull_state, pull_detail:$pull_detail,
      digest:$digest, sig_state:$sig_state, sig_identity:$sig_identity,
      has_sbom:$has_sbom, has_provenance:$has_provenance,
      created:$created, age_days:$age_days, stale:$stale, healthy:$healthy}' \
    >> "$tmp/rows.jsonl"
}

# --- orphan reconciliation ---------------------------------------------------
#
# Lists container packages owned by $owner and flags any ci-* package that is
# not in images.json. This is the check most likely to be denied outright:
# listing a USER's packages is a user-scoped endpoint, and GITHUB_TOKEN's
# packages:read is normally enough only for packages linked to the calling
# repository, not for enumerating everything the owner has ever published.
# When that is the case this is skipped, loudly, rather than silently
# reporting zero orphans as if none existed.
orphan_checked=false
orphan_skip_reason=""
orphans_json='[]'

check_orphans() {
  local raw
  if ! raw=$(gh api "/users/${owner}/packages?package_type=container&per_page=100" --paginate 2>"$tmp/orphan_err.txt"); then
    orphan_skip_reason="cannot list packages for user $owner: $(tr '\n' ' ' <"$tmp/orphan_err.txt" | cut -c1-300)"
    log info "orphan check skipped: $orphan_skip_reason"
    return 0
  fi
  # gh --paginate on an array endpoint concatenates one JSON array per page;
  # slurp and flatten so multi-page responses collapse to one list either way.
  if ! raw=$(jq -c -s 'add // []' <<<"$raw" 2>"$tmp/orphan_err.txt"); then
    orphan_skip_reason="unexpected response listing packages for $owner: $(tr '\n' ' ' <"$tmp/orphan_err.txt" | cut -c1-300)"
    log info "orphan check skipped: $orphan_skip_reason"
    return 0
  fi

  orphan_checked=true
  orphans_json=$(jq -c --argjson known "$(jq -c '[.[].image]' .github/images.json)" '
      [.[] | select(.name | test("^ci-")) | select(.name as $n | $known | index($n) | not) | .name]
    ' <<<"$raw")
  log info "orphan check: $(jq 'length' <<<"$orphans_json") ci-* package(s) not in images.json"
}

# --- main --------------------------------------------------------------------
while IFS=$'\t' read -r image version; do
  [ -n "$image" ] || continue
  audit_image "$image" "$version"
done < <(jq -r '.[] | [.image, .version] | @tsv' .github/images.json)

check_orphans
orphan_count=$(jq 'length' <<<"$orphans_json")
[ "$orphan_count" -gt 0 ] && issues=$((issues + 1))

if [ "$format" = json ]; then
  jq -s \
    --argjson issues "$issues" \
    --argjson orphan_checked "$orphan_checked" \
    --arg orphan_skip_reason "$orphan_skip_reason" \
    --argjson orphans "$orphans_json" \
    '{issues:$issues, images:., orphans:{checked:$orphan_checked, skip_reason:$orphan_skip_reason, packages:$orphans}}' \
    "$tmp/rows.jsonl"
else
  printf '%-14s %-14s %-8s %-8s %-6s %-6s %-7s %s\n' IMAGE VERSION PULL SIG SBOM PROV STALE AGE_D
  jq -r '[.image,.version,.pull_state,.sig_state,.has_sbom,.has_provenance,.stale,(.age_days // "?")] | @tsv' "$tmp/rows.jsonl" \
    | while IFS=$'\t' read -r i v p s sb pr st ad; do
        printf '%-14s %-14s %-8s %-8s %-6s %-6s %-7s %s\n' "$i" "$v" "$p" "$s" "$sb" "$pr" "$st" "$ad"
      done
  echo
  if [ "$orphan_checked" = true ]; then
    echo "orphan packages not in images.json: ${orphan_count}"
    [ "$orphan_count" -gt 0 ] && jq -r '.[]' <<<"$orphans_json" | sed 's/^/  - /'
  else
    echo "orphan check skipped: $orphan_skip_reason"
  fi
  echo
  printf 'issues=%d\n' "$issues"
fi

[ "$issues" -gt 0 ] && { log info "$issues issue(s) found"; exit "$EXIT_ISSUES"; }
log info "every published image is healthy"
exit 0
