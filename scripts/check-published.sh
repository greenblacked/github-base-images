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
# true the moment it pushed --  pullable, correctly signed by the expected
# workflow, carrying both SBOM and provenance attestations, and no older than
# a weekly rebuild plus margin.
#
# Deliberately out of scope: enumerating every ci-* package this owner has
# ever published to find ones no longer in images.json. GitHub's Packages
# listing API needs a classic PAT with read:packages -- GITHUB_TOKEN, an
# installation token, cannot call it -- and this repository is not adding
# that credential. A check that can never run in CI is worse than no check:
# it looks like coverage in the workflow file while providing none. The two
# retired names this would have caught (ci-go125, ci-rust185) are instead
# being deleted at the source.
#
# Assumes docker buildx, cosign, jq are already on PATH -- the calling
# workflow installs docker and cosign; jq is already on any GitHub-hosted
# runner. Same division of labour as check-pins.sh, which assumes curl and jq
# are already there.
#
#   ./scripts/check-published.sh                 # human-readable table
#   ./scripts/check-published.sh --format json   # machine-readable, for the workflow
#
# Exit codes:
#   0  every image is healthy and current
#   1  a script-level failure -- a broken checker, not a broken registry: an
#      image whose attestations or freshness could not be determined at all,
#      with no confirmed issue elsewhere
#   2  bad usage, or .github/images.json could not be read at all
#   3  one or more images unhealthy or stale -- a normal, expected outcome,
#      not an error. Outranks exit 1: a confirmed problem must still reach
#      the tracking issue even if some other, unrelated check was itself
#      broken this run.
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

for cmd in docker cosign jq date awk; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root" || { echo "error: cannot enter repo root" >&2; exit 1; }

# Both branches of this default have their own fallback, so neither side ever
# references an unset variable directly under `set -u` -- OWNER unset AND
# GITHUB_REPOSITORY unset must not abort the script.
owner="${OWNER:-${GITHUB_REPOSITORY:-greenblacked/github-base-images}}"
owner="${owner%%/*}"
repo_slug="${REPO_SLUG:-${GITHUB_REPOSITORY:-greenblacked/github-base-images}}"

# The identity a signature is expected to carry. Signing happens inside
# build-image.yml (the REUSABLE workflow), not build-and-push.yml (the
# caller) -- Fulcio binds the certificate to whichever workflow file the
# signing job actually runs, so the caller's name never appears here. Only
# `.` needs escaping; owner/repo characters are regex-safe.
identity_regexp="^https://github\\.com/${repo_slug//./\\.}/\\.github/workflows/build-image\\.yml@refs/heads/main\$"
# Rung 2 of the identity ladder in verify_signature: signed by this
# repository at all, regardless of which workflow or ref. Same escaping.
repo_identity_regexp="^https://github\\.com/${repo_slug//./\\.}/"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

: > "$tmp/rows.jsonl"
issues=0
failed=0
checked=0

# --- per-image checks --------------------------------------------------------
#
# check_pull sets: pull_state (ok|missing|private|error), digest, inspect_text
check_pull() {
  local ref="$1"
  if inspect_text=$(docker buildx imagetools inspect "$ref" 2>"$tmp/pull_err.txt"); then
    pull_state=ok
    pull_detail=""
    digest=$(awk '/^Digest:/ {print $2; exit}' <<<"$inspect_text")
  else
    local err; err=$(cat "$tmp/pull_err.txt")
    case "$err" in
      *"failed to fetch anonymous token"*|*403*)
        # Verified against live GHCR: this -- not a private package -- is
        # what a pull of a package that DOES NOT EXIST returns. This used to
        # be read as "private" and called deliberate and unremarkable; it
        # was actually classifying deleted packages that way, silently.
        pull_state=missing ;;
      *401*|*[Uu]nauthorized*|*denied*|*insufficient_scope*)
        # A token that authenticated but was refused, as opposed to one that
        # could not even be issued (above) -- the shape of a package that
        # exists but is genuinely access-restricted from this token. Still
        # unhealthy below: a consumer without special access could not pull
        # it either, so "private" is a diagnosis, not a pass.
        pull_state=private ;;
      *404*|*"not found"*|*"manifest unknown"*|*"name unknown"*)
        pull_state=missing ;;
      *)
        pull_state=error ;;
    esac
    digest=""
    pull_detail=$(tr '\n' ' ' <<<"$err" | cut -c1-300)
  fi
  return 0
}

# verify_signature sets: sig_state (ok|fail|skipped), sig_identity -- a
# description of which identity-ladder rung matched, never a raw certificate
# `Subject` field.
#
# cosign-installer v4.1.2 installs cosign v3.0.6, whose default
# --new-bundle-format=true makes `cosign verify` return signatures as OCI
# referrers in sigstore bundle format. On that path `transformOutput` wraps
# the result with `static.NewAttestation(p)`, which carries no certificate
# chain -- `Cert()` returns nil, and `PrintVerification`'s json branch only
# ever sets `.optional.Subject` when a cert is present. There is no
# certificate identity in this JSON to read, on any image this repository
# has ever published, or ever will on this code path.
#
# Pass/fail is unaffected by any of that: the rung-1 call below is what
# decides sig_state, and --certificate-identity-regexp is enforced inside
# `cosign verify` itself (co.Identities), a real cryptographic check. Rungs 2
# and 3 run only to explain a rung-1 failure -- re-verifying with
# successively looser identity patterns and reporting which one matched,
# instead of reading a field that cannot be populated.
verify_signature() {
  local digest_ref="$1"

  if cosign verify \
        --certificate-oidc-issuer "$COSIGN_ISSUER" \
        --certificate-identity-regexp "$identity_regexp" \
        --output json "$digest_ref" >/dev/null 2>"$tmp/verify_err.txt"; then
    sig_state=ok
    sig_identity="rung 1/3: matches the expected identity (${repo_slug}, build-image.yml@refs/heads/main)"
    return 0
  fi
  sig_state=fail

  if cosign verify \
        --certificate-oidc-issuer "$COSIGN_ISSUER" \
        --certificate-identity-regexp "$repo_identity_regexp" \
        --output json "$digest_ref" >/dev/null 2>>"$tmp/verify_err.txt"; then
    sig_identity="rung 2/3: signed by ${repo_slug}, but not the expected workflow/ref (a renamed workflow, or a ref that is not refs/heads/main)"
    return 0
  fi

  if cosign verify \
        --certificate-oidc-issuer "$COSIGN_ISSUER" \
        --certificate-identity-regexp '.*' \
        --output json "$digest_ref" >/dev/null 2>>"$tmp/verify_err.txt"; then
    sig_identity="rung 3/3: signed under the GitHub Actions OIDC issuer, but not by ${repo_slug} at all"
    return 0
  fi

  # No rung matched under this issuer at all: no valid signature. Prefer
  # cosign's own `Error:` line over whatever precedes it -- v3.0.6 routinely
  # writes a `WARNING:` line first, which is what used to be captured here
  # instead of the actual error.
  local err_text err_line
  err_text=$(<"$tmp/verify_err.txt")
  err_line=$(printf '%s\n' "$err_text" | grep -m1 '^Error:' || true)
  if [ -n "$err_line" ]; then
    sig_identity="no valid signature: $(printf '%s' "$err_line" | cut -c1-300)"
  else
    sig_identity="no valid signature: $(printf '%s' "$err_text" | tr '\n' ' ' | cut -c1-300)"
  fi
  return 0
}

# attestations sets: has_sbom, has_provenance (each "true"/"false" -- present
# or genuinely absent -- or "unknown" when the checker itself could not
# tell), and attest_detail (the stderr from whichever inspect call failed,
# kept rather than discarded).
check_attestations() {
  local digest_ref="$1" sbom_json provenance_json
  has_sbom=false; has_provenance=false; attest_detail=""

  # buildx only ever fails this command for a real reason -- a blob it
  # cannot reach, a network error, a bad ref. A genuinely missing
  # attestation is not a failure at all: buildx's result.SBOM()/Provenance()
  # only insert a platform key when an attestation manifest exists, so the
  # command exits 0 and prints `{}` (or `null`) when there simply is none.
  # Success and failure are therefore handled in separate branches below,
  # rather than folded together with `2>/dev/null || true`, which used to
  # make both cases look identical -- an unreachable registry reported as
  # "no attestations" instead of "could not check".
  if sbom_json=$(docker buildx imagetools inspect --format '{{json .SBOM}}' "$digest_ref" 2>"$tmp/sbom_err.txt"); then
    if [ -n "$sbom_json" ] && [ "$sbom_json" != "null" ] && [ "$sbom_json" != "{}" ]; then
      has_sbom=true
    fi
  else
    has_sbom=unknown
    attest_detail="${attest_detail}SBOM inspect failed: $(tr '\n' ' ' <"$tmp/sbom_err.txt" | cut -c1-200)  "
  fi

  if provenance_json=$(docker buildx imagetools inspect --format '{{json .Provenance}}' "$digest_ref" 2>"$tmp/provenance_err.txt"); then
    if [ -n "$provenance_json" ] && [ "$provenance_json" != "null" ] && [ "$provenance_json" != "{}" ]; then
      has_provenance=true
    fi
  else
    has_provenance=unknown
    attest_detail="${attest_detail}Provenance inspect failed: $(tr '\n' ' ' <"$tmp/provenance_err.txt" | cut -c1-200)"
  fi
  return 0
}

# freshness sets: created (RFC3339 or empty), age_days (int or empty),
# freshness_state (ok|stale|unknown) and freshness_detail. "unknown" is a
# distinct state everywhere it is used below -- it must never be read as a
# pass, which is what an undetermined age used to become once `stale`
# defaulted to false regardless of why age_days came back empty.
check_freshness() {
  local digest_ref="$1" image_json
  created=""; age_days=""; freshness_state=unknown; freshness_detail=""

  if ! image_json=$(docker buildx imagetools inspect --format '{{json .Image}}' "$digest_ref" 2>"$tmp/image_err.txt"); then
    freshness_detail="buildx inspect failed: $(tr '\n' ' ' <"$tmp/image_err.txt" | cut -c1-200)"
    return 0
  fi
  if [ -z "$image_json" ] || [ "$image_json" = "null" ]; then
    freshness_detail="empty .Image output from buildx"
    return 0
  fi

  # `.Image` is normally an object keyed by platform (or a single config for
  # a single-platform image), but jq's `has()` throws (exit 5) if it is ever
  # handed something else. Guard the type first, so a surprising shape is a
  # normal "could not determine" outcome rather than a crash the caller has
  # to survive with `|| true` -- which is what silently turned this failure
  # into an empty, passing `age_days` before.
  if ! created=$(jq -r '
      if type != "object" then empty
      elif has("linux/amd64") then .["linux/amd64"].created
      elif has("created") then .created
      else (to_entries[0].value.created // empty)
      end // empty' <<<"$image_json" 2>"$tmp/image_jq_err.txt"); then
    freshness_detail="could not parse .Image JSON: $(tr '\n' ' ' <"$tmp/image_jq_err.txt" | cut -c1-200)"
    created=""
    return 0
  fi
  if [ -z "$created" ]; then
    freshness_detail="no creation timestamp in .Image output"
    return 0
  fi

  local created_epoch now_epoch
  if ! created_epoch=$(date -u -d "$created" +%s 2>"$tmp/date_err.txt"); then
    freshness_detail="unparsable creation timestamp '$created': $(tr '\n' ' ' <"$tmp/date_err.txt" | cut -c1-200)"
    return 0
  fi
  now_epoch=$(date -u +%s)
  age_days=$(( (now_epoch - created_epoch) / 86400 ))
  if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
    freshness_state=stale
  else
    freshness_state=ok
  fi
  return 0
}

audit_image() {
  local image="$1" version="$2" ref digest_ref
  ref="ghcr.io/${owner}/${image}:${version}"

  log info "auditing $ref"
  check_pull "$ref"

  sig_state=skipped; sig_identity=""
  has_sbom=false; has_provenance=false; attest_detail=""
  created=""; age_days=""; freshness_state=unknown
  freshness_detail="not checked: image could not be pulled"

  if [ "$pull_state" = ok ]; then
    digest_ref="ghcr.io/${owner}/${image}@${digest}"
    verify_signature "$digest_ref"
    check_attestations "$digest_ref"
    check_freshness "$digest_ref"
  fi

  # A row is "issue" when some dimension is definitively, observably broken
  # -- a real registry-side fact, worth a tracking issue. It is "error" when
  # a dimension could not be determined at all -- a broken checker, not a
  # broken registry (see check_attestations/check_freshness above) -- and
  # that must never silently read as healthy either. "issue" outranks
  # "error": a real, confirmed problem on one dimension must not be hidden
  # behind an unrelated checker hiccup on another dimension of the same
  # image.
  local has_issue=false has_unknown=false

  [ "$pull_state" = ok ] || has_issue=true
  [ "$sig_state" = ok ] || has_issue=true

  if [ "$has_sbom" = unknown ] || [ "$has_provenance" = unknown ]; then
    has_unknown=true
  elif [ "$has_sbom" != true ] || [ "$has_provenance" != true ]; then
    has_issue=true
  fi

  case "$freshness_state" in
    ok) ;;
    stale) has_issue=true ;;
    unknown) has_unknown=true ;;
  esac

  local status healthy
  if [ "$has_issue" = true ]; then
    status=issue; healthy=false
    issues=$((issues + 1))
    log info "$ref: unhealthy (pull=$pull_state sig=$sig_state sbom=$has_sbom provenance=$has_provenance freshness=$freshness_state)"
  elif [ "$has_unknown" = true ]; then
    status=error; healthy=false
    failed=$((failed + 1))
    log info "$ref: could not fully audit (sbom=$has_sbom provenance=$has_provenance freshness=$freshness_state) -- ${attest_detail}${freshness_detail}"
  else
    status=healthy; healthy=true
  fi

  jq -nc \
    --arg image "$image" --arg version "$version" --arg ref "$ref" \
    --arg pull_state "$pull_state" --arg pull_detail "${pull_detail:-}" \
    --arg digest "${digest:-}" \
    --arg sig_state "$sig_state" --arg sig_identity "$sig_identity" \
    --arg has_sbom "$has_sbom" --arg has_provenance "$has_provenance" --arg attest_detail "${attest_detail:-}" \
    --arg created "$created" \
    --argjson age_days "${age_days:-null}" --arg freshness_state "$freshness_state" \
    --arg freshness_detail "${freshness_detail:-}" \
    --arg status "$status" --argjson healthy "$healthy" \
    '{image:$image, version:$version, ref:$ref, pull_state:$pull_state, pull_detail:$pull_detail,
      digest:$digest, sig_state:$sig_state, sig_identity:$sig_identity,
      has_sbom:$has_sbom, has_provenance:$has_provenance, attest_detail:$attest_detail,
      created:$created, age_days:$age_days, freshness_state:$freshness_state, freshness_detail:$freshness_detail,
      status:$status, healthy:$healthy}' \
    >> "$tmp/rows.jsonl"
}

# --- main --------------------------------------------------------------------
while IFS=$'\t' read -r image version; do
  [ -n "$image" ] || continue
  checked=$((checked + 1))
  audit_image "$image" "$version"
done < <(jq -r '.[] | [.image, .version] | @tsv' .github/images.json)

# A jq failure reading .github/images.json (malformed JSON, wrong shape) is
# invisible to `set -eo pipefail` inside a `< <(...)` process substitution --
# the loop above would simply run zero times and this would otherwise report
# "every published image is healthy" having checked nothing at all. Mirrors
# the same assertion in check-pins.sh.
if [ "$checked" -eq 0 ]; then
  echo "error: no images parsed from .github/images.json -- malformed file or jq failure" >&2
  exit 2
fi

if [ "$format" = json ]; then
  jq -s \
    --argjson issues "$issues" \
    --argjson failed "$failed" \
    '{issues:$issues, failed:$failed, images:.}' \
    "$tmp/rows.jsonl"
else
  printf '%-14s %-14s %-8s %-8s %-6s %-6s %-9s %-7s %s\n' IMAGE VERSION PULL SIG SBOM PROV FRESH STATUS AGE_D
  jq -r '[.image,.version,.pull_state,.sig_state,.has_sbom,.has_provenance,.freshness_state,.status,(.age_days // "?")] | @tsv' "$tmp/rows.jsonl" \
    | while IFS=$'\t' read -r i v p s sb pr fr st ad; do
        printf '%-14s %-14s %-8s %-8s %-6s %-6s %-9s %-7s %s\n' "$i" "$v" "$p" "$s" "$sb" "$pr" "$fr" "$st" "$ad"
      done
  echo
  printf 'issues=%d failed=%d\n' "$issues" "$failed"
fi

if [ "$issues" -gt 0 ]; then
  log info "$issues issue(s) found"
  [ "$failed" -gt 0 ] && log info "additionally, $failed check(s) could not be determined (a broken checker, not counted as a registry issue)"
  exit "$EXIT_ISSUES"
fi
if [ "$failed" -gt 0 ]; then
  log error "$failed check(s) could not be determined -- treating this run as a broken checker, not a clean audit"
  exit 1
fi
log info "every published image is healthy"
exit 0
