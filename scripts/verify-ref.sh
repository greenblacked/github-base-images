#!/usr/bin/env bash
# Post-sign verification of one published digest, with a bounded retry: runs
# `scripts/check-published.sh --ref REF` until it passes or the attempts run
# out. Run by build-image.yml's merge job twice -- straight after `cosign
# sign`, and again after the GitHub attestation is attached
# (--after-attestation, which changes only the messages).
#
#   ./scripts/verify-ref.sh ghcr.io/<owner>/<image>@sha256:<digest>
#   ./scripts/verify-ref.sh --after-attestation ghcr.io/<owner>/<image>@sha256:<digest>
#
# Why retry: the check reads the signature and attestations back from the
# registry seconds after they were written, and that read is not reliably
# consistent yet. On one publish run a single image came back
# `sig=fail sbom=true provenance=true` four seconds after `cosign sign`,
# while the other twenty passed the same step and a re-run of the same job
# passed -- the signature had not propagated yet, nothing was wrong with it.
# A lag like that must not turn a good publish red.
#
# What is retried: exit 3 (an issue found -- which may be the lag) and exit 1
# (the check could not run -- a registry or transparency-log hiccup). Up to
# four attempts, waiting 10s, 20s and 40s between them (70s in all, enough
# for propagation and short enough that a real regression still fails the
# run promptly). Every attempt is logged, and every failed one as a warning,
# so a check that needed retries is visible. Only the last attempt decides:
# a signature that still does not verify after them fails exactly as before.
# Anything else -- 2, bad usage, or an unexpected code -- is not something
# waiting fixes, so it fails at once, without retrying.
#
# VERIFY_REF_DELAYS overrides the waits, one per retry (default "10 20 40",
# so four attempts; the attempt count is always one more than the waits).
# VERIFY_REF_CHECK overrides the checker (default: check-published.sh next to
# this script). Both are for the offline tests, scripts/test-verify-ref.sh.
# OWNER and REPO_SLUG pass through to check-published.sh unchanged.
#
# Exit: 0 verified; otherwise the last attempt's check-published.sh exit code
# (3 issue found, 1 could not check, anything else as it came); 2 usage.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
check="${VERIFY_REF_CHECK:-$here/check-published.sh}"

usage() { echo "usage: verify-ref.sh [--after-attestation] REPO@sha256:DIGEST" >&2; exit 2; }

after=false
case "${1:-}" in
  --after-attestation) after=true; shift ;;
esac
if [ $# -ne 1 ] || [ -z "$1" ]; then usage; fi
ref="$1"

read -r -a delays <<< "${VERIFY_REF_DELAYS-10 20 40}"
for d in ${delays[@]+"${delays[@]}"}; do
  [[ "$d" =~ ^[0-9]+$ ]] || { echo "error: VERIFY_REF_DELAYS must be whole seconds, got '$d'" >&2; exit 2; }
done
attempts=$(( ${#delays[@]} + 1 ))

if [ "$after" = true ]; then
  what="re-verify $ref after attestation"
else
  what="verify $ref"
fi

rc=1
attempt=0
while [ "$attempt" -lt "$attempts" ]; do
  attempt=$((attempt + 1))
  echo "verify-ref: attempt $attempt of $attempts: check-published.sh --ref $ref"
  rc=0
  "$check" --ref "$ref" || rc=$?
  case "$rc" in
    0) break ;;
    1|3) ;;
    *) break ;;
  esac
  if [ "$attempt" -lt "$attempts" ]; then
    wait_s="${delays[$((attempt - 1))]}"
    echo "::warning::attempt $attempt of $attempts to $what failed (check-published.sh exit $rc); retrying in ${wait_s}s"
    sleep "$wait_s"
  else
    echo "::warning::attempt $attempt of $attempts to $what failed (check-published.sh exit $rc); no attempts left"
  fi
done

n="$attempt attempt"; [ "$attempt" -eq 1 ] || n="${n}s"
case "$rc:$after" in
  0:false) echo "verified: $ref is signed by the expected identity and carries SBOM and provenance attestations (attempt $attempt of $attempts)" ;;
  0:true)  echo "verified: $ref still verifies with the GitHub attestation attached (attempt $attempt of $attempts)" ;;
  3:false) echo "::error::$ref failed post-sign verification after $n: the signature does not verify under the expected identity, or an SBOM/provenance attestation is missing (see the table above)" ;;
  3:true)  echo "::error::$ref passed post-sign verification before the GitHub attestation was attached and fails it now, after $n: the signature no longer verifies under the expected identity, or an SBOM/provenance attestation is no longer found (see the table above)" ;;
  1:false) echo "::error::could not verify $ref after $n: the signature or attestation check itself failed to run (see the log above) -- treated as a failure, not a pass" ;;
  1:true)  echo "::error::could not re-verify $ref after attestation, after $n: the signature or attestation check itself failed to run (see the log above) -- treated as a failure, not a pass" ;;
  *)       echo "::error::check-published.sh --ref exited $rc on attempt $attempt (usage or unexpected error; not retried)" ;;
esac
exit "$rc"
