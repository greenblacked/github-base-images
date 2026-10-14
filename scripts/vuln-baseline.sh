#!/usr/bin/env bash
# Find the image a consumer pulls today for one image, tag and architecture:
# the baseline the vulnerability gate compares a build with
# (scripts/vuln-gate.sh, docs/adr/0008-self-updating.md). Run by
# build-image.yml's "Published baseline" step, and -- with --upstream, below --
# by its "Base image baseline" step.
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
# Authenticated when REGISTRY_USER and REGISTRY_TOKEN are set (build-image.yml
# passes the job's own GITHUB_TOKEN, which needs only `packages: read`), so a
# private package can be read as a baseline too -- anonymously it could not,
# the gate would run strict on every pull request, and a bot PR for that image
# could never go green. The login goes into a throwaway DOCKER_CONFIG made
# here and deleted when this script exits, so nothing that runs after it (the
# build steps, third-party actions) inherits the credential. A login that
# fails is treated like an unreadable registry: strict, with a warning. With
# neither variable set (a local run), the reads are anonymous, which works
# for the public packages.
#
# Registry reads are retried: up to four, 5s, 15s and 45s apart, so one
# hiccup does not make the gate strict -- which, for an image carrying known
# upstream findings, means red. "Not found" is an answer, not a hiccup, and
# is not retried: a missing tag or package is what a new image looks like.
# VULN_BASELINE_DELAYS overrides the delays (the offline tests use 0s).
#
# The upstream base, the gate's second baseline:
#
#   ./scripts/vuln-baseline.sh --upstream <image-ref> <arch>
#
# finds the per-arch image of the base the build is FROM -- the BASE_IMAGE
# build-arg build-image.yml passed: the upstream ref itself on a pull request,
# ghcr.io/<owner>/mirror-...:<tag> on main -- by the same index read, the same
# retries and the same one-linux/<arch>-manifest rule, so the base is scanned
# for the architecture that was built and by a digest that cannot move
# between this step and the scan. <image-ref> is any reference Docker accepts:
# `debian:bookworm-slim` (Docker Hub), `mcr.microsoft.com/dotnet/sdk:8.0`, a
# ghcr.io mirror tag. The outputs are the same two lines; what differs is what
# an empty ref means. Without an upstream baseline the gate simply compares
# with the published image alone, exactly as it did before there was one, so
# every way of not finding the base is a ::notice, not a warning, and the
# messages say that instead of "strict". Credentials, when set, are used only
# for the registry the ref names; build-image.yml sets them only for a ref on
# ghcr.io, so the job token is never offered to Docker Hub or mcr.
#
# Exit: 0 with the outputs above; 2 usage. Requires docker (with buildx) and jq.
set -euo pipefail

usage() {
  echo "usage: vuln-baseline.sh <repo> <version> <arch>" >&2
  echo "       vuln-baseline.sh --upstream <image-ref> <arch>" >&2
  exit 2
}
mode=published
if [ "${1:-}" = --upstream ]; then
  [ $# -eq 3 ] && [ -n "$2" ] && [ -n "$3" ] || usage
  mode=upstream
  ref_in="$2" arch="$3"
  # Split the reference into its repository and its tag or digest: the tag is
  # what follows the last ":" only when that ":" comes after the last "/"
  # (a registry port, as in localhost:5000/x, is not a tag).
  if [[ "$ref_in" == *@* ]]; then
    repo="${ref_in%%@*}"
  elif [[ "${ref_in##*/}" == *:* ]]; then
    repo="${ref_in%:*}"
  else
    repo="$ref_in"
  fi
  image="$ref_in"
  # The registry: the first path component when it looks like a host
  # (has a "." or a ":", or is localhost); otherwise Docker Hub.
  first="${repo%%/*}"
  if [ "$first" != "$repo" ] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [ "$first" = localhost ]; }; then
    registry="$first"
  else
    registry=docker.io
  fi
else
  [ $# -eq 3 ] || usage
  repo="$1" version="$2" arch="$3"
  image="$repo:$version"
  registry="${repo%%/*}"
fi
out=${GITHUB_OUTPUT:-/dev/stdout}
read -r -a delays <<< "${VULN_BASELINE_DELAYS:-5 15 45}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# LEVEL MESSAGE -- no baseline: say why, as an annotation, and stop. For the
# upstream base every level is a notice: going without it is how the gate
# worked before it existed, not a degraded gate.
strict() {
  echo "ref=" >> "$out"
  echo "note=$2" >> "$out"
  if [ "$mode" = upstream ]; then
    echo "::notice::$2 -- the vulnerability gate runs without the base-image baseline for $arch: it compares with the published image only"
  else
    echo "::$1::$2 -- the vulnerability gate runs strict for $arch: every finding blocks"
  fi
  exit 0
}
retry_level=warning
[ "$mode" = upstream ] && retry_level=notice

if [ -n "${REGISTRY_USER:-}" ] && [ -n "${REGISTRY_TOKEN:-}" ]; then
  # Inside $tmp, so the EXIT trap removes it with the credential in it. The
  # CLI plugins (buildx) are found through the config dir, so the user's are
  # linked in, read-only use.
  export DOCKER_CONFIG="$tmp/docker-config"
  mkdir -p "$DOCKER_CONFIG"
  # buildx keeps its builder instances under the config dir too, so a builder
  # named by BUILDX_BUILDER (setup-buildx-action may export one) does not
  # exist in this one; `imagetools inspect` needs no particular builder, and
  # the default one always exists.
  unset BUILDX_BUILDER
  [ -d "${HOME:-/nonexistent}/.docker/cli-plugins" ] && ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG/cli-plugins"
  rc=0
  printf '%s' "$REGISTRY_TOKEN" | docker login "$registry" --username "$REGISTRY_USER" --password-stdin \
    > /dev/null 2> "$tmp/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    strict warning "could not log in to $registry to read $image (exit $rc: $(tr '\n' ' ' < "$tmp/err" | cut -c1-200))"
  fi
fi

attempts=$(( ${#delays[@]} + 1 ))
rc=0
for ((i = 0; i < attempts; i++)); do
  rc=0
  docker buildx imagetools inspect --raw "$image" > "$tmp/index.json" 2> "$tmp/err" || rc=$?
  [ "$rc" -eq 0 ] && break
  if grep -qiE 'not found|manifest unknown|name unknown' "$tmp/err"; then
    if [ "$mode" = upstream ]; then
      strict notice "the base image $image was not found in the registry"
    fi
    strict notice "$image has never been published (new image or new tag)"
  fi
  if [ "$i" -lt "${#delays[@]}" ]; then
    echo "::$retry_level::reading $image failed (exit $rc: $(tr '\n' ' ' < "$tmp/err" | cut -c1-200)); retrying in ${delays[$i]}s"
    sleep "${delays[$i]}"
  fi
done
if [ "$rc" -ne 0 ]; then
  strict warning "could not read $image from the registry after $attempts attempts (exit $rc: $(tr '\n' ' ' < "$tmp/err" | cut -c1-200))"
fi

rc=0
digest=$(jq -r --arg arch "$arch" '
  if (.manifests | type) != "array" then error("not an image index") else . end
  | [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
  | if length == 1 and (.[0] | test("^sha256:[0-9a-f]{64}$")) then .[0] else error("\(length) linux/\($arch) manifests") end
  ' "$tmp/index.json" 2> "$tmp/err") || rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$mode" = upstream ]; then
    strict notice "the base image $image has no single linux/$arch manifest ($(tr '\n' ' ' < "$tmp/err" | cut -c1-200))"
  fi
  strict warning "the published $image has no single linux/$arch manifest ($(tr '\n' ' ' < "$tmp/err" | cut -c1-200))"
fi
echo "ref=$repo@$digest" >> "$out"
echo "note=" >> "$out"
if [ "$mode" = upstream ]; then
  echo "base image for $arch: $repo@$digest ($image)"
else
  echo "baseline for $arch: $repo@$digest ($image)"
fi
