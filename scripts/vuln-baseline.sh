#!/usr/bin/env bash
# Find the image a consumer pulls today for one image, tag and architecture:
# the baseline the vulnerability gate compares a build with
# (scripts/vuln-gate.sh, docs/adr/0008-self-updating.md). Run by
# build-image.yml's "Published baseline" step.
#
#   ./scripts/vuln-baseline.sh ghcr.io/<owner>/<image> <version> <arch>
#
# Reads the index behind the rolling tag and picks its one linux/<arch>
# manifest. Not the `<version>-<arch>` tag build-image.yml's push step writes:
# that tag moves as soon as one architecture passes, even when the other then
# fails and the index is never updated, so it can name an image nobody was
# given.
#
# Writes two lines to $GITHUB_OUTPUT (or stdout when that is unset):
#   ref=<repo>@sha256:...   and note=        when a baseline was found
#   ref=                    and note=<why>   when not
# and never fails for want of a baseline: every way of not finding one is an
# empty ref plus a note, and the gate step turns that into the strict
# comparison (every finding blocks). It does not tell the gate what to do; it
# only says what it found.
#
# Registry reads are retried: up to four, 5s, 15s and 45s apart, so one
# hiccup does not make the gate strict -- which, for an image carrying known
# upstream findings, means red. "Not found" is an answer, not a hiccup, and
# is not retried: a missing tag or package is what a new image looks like.
# VULN_BASELINE_DELAYS overrides the delays (the offline tests use 0s).
#
# Exit: 0 with the outputs above; 2 usage. Requires docker (with buildx) and jq.
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "usage: vuln-baseline.sh <repo> <version> <arch>" >&2
  exit 2
fi
repo="$1" version="$2" arch="$3"
out=${GITHUB_OUTPUT:-/dev/stdout}
read -r -a delays <<< "${VULN_BASELINE_DELAYS:-5 15 45}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# LEVEL MESSAGE -- no baseline: say why, as an annotation, and stop.
strict() {
  echo "ref=" >> "$out"
  echo "note=$2" >> "$out"
  echo "::$1::$2 -- the vulnerability gate runs strict for $arch: every finding blocks"
  exit 0
}

attempts=$(( ${#delays[@]} + 1 ))
rc=0
for ((i = 0; i < attempts; i++)); do
  rc=0
  docker buildx imagetools inspect --raw "$repo:$version" > "$tmp/index.json" 2> "$tmp/err" || rc=$?
  [ "$rc" -eq 0 ] && break
  if grep -qiE 'not found|manifest unknown|name unknown' "$tmp/err"; then
    strict notice "$repo:$version has never been published (new image or new tag)"
  fi
  if [ "$i" -lt "${#delays[@]}" ]; then
    echo "::warning::reading $repo:$version failed (exit $rc: $(tr '\n' ' ' < "$tmp/err" | cut -c1-200)); retrying in ${delays[$i]}s"
    sleep "${delays[$i]}"
  fi
done
if [ "$rc" -ne 0 ]; then
  strict warning "could not read $repo:$version from the registry after $attempts attempts (exit $rc: $(tr '\n' ' ' < "$tmp/err" | cut -c1-200))"
fi

rc=0
digest=$(jq -r --arg arch "$arch" '
  if (.manifests | type) != "array" then error("not an image index") else . end
  | [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
  | if length == 1 and (.[0] | test("^sha256:[0-9a-f]{64}$")) then .[0] else error("\(length) linux/\($arch) manifests") end
  ' "$tmp/index.json" 2> "$tmp/err") || rc=$?
if [ "$rc" -ne 0 ]; then
  strict warning "the published $repo:$version has no single linux/$arch manifest ($(tr '\n' ' ' < "$tmp/err" | cut -c1-200))"
fi
echo "ref=$repo@$digest" >> "$out"
echo "note=" >> "$out"
echo "baseline for $arch: $repo@$digest ($repo:$version)"
