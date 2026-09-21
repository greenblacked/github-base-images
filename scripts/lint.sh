#!/usr/bin/env bash
# The lint battery. This script IS the `lint` job -- CI checks out the repo and
# runs it, so local-clean means CI-lint-clean by construction rather than by
# convention:
#
#   make lint
#
# It did not always work that way. CI used to run hadolint and actionlint via
# marketplace actions while this script ran its own pinned copies, and keeping
# the two in step was left to whoever noticed. Twice it was not noticed, both
# times a Dependabot bump of hadolint-action -- which bundles a hadolint binary
# -- putting local and CI on different linters while CI stayed green, because
# nothing in that job read this file. There is now one version of each engine,
# here.
#
# Engines are downloaded once into .lint-cache/ (git-ignored) as pinned,
# checksum-verified release binaries -- the same pattern as the ci-tools
# binaries, Composer, and gitleaks in security.yml.
#
# zizmor runs best-effort at the end when available (pip install zizmor, or
# uv). Its findings are reported, not gating -- the same posture as CI.
set -euo pipefail

# These two are now the only place either engine's version is set: CI runs this
# script, so there is no second copy to keep in step. Bumping one is a one-line
# change plus its checksums below, and nothing else in the repository has to
# move with it.
#
# Neither is tracked by Dependabot -- they are plain shell variables, not action
# pins -- so they drift until a human moves them, exactly like the tool pins in
# the Dockerfiles. Unlike those, they are not in scripts/check-pins.sh either.
HADOLINT_VERSION=2.15.1
ACTIONLINT_VERSION=1.7.10

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/.lint-cache"
mkdir -p "$CACHE"
cd "$ROOT"

os="$(uname -s)" arch="$(uname -m)"
fail=0

note()  { printf '\n== %s\n' "$*"; }
die()   { printf 'error: %s\n' "$*" >&2; exit 2; }

# fetch <url> <dest> <sha256> -- cached download with mandatory verification.
fetch() {
  local url="$1" dest="$2" sum="$3"
  if [ -f "$dest" ] && echo "$sum  $dest" | sha256sum --check --status - 2>/dev/null; then
    return 0
  fi
  curl -fsSL --retry 3 -o "$dest.tmp" "$url"
  echo "$sum  $dest.tmp" > "$dest.sum"
  sha256sum --check --status "$dest.sum" || die "checksum mismatch for $url"
  rm -f "$dest.sum"
  mv "$dest.tmp" "$dest"
}

# --- hadolint: pinned release binary on Linux; PATH fallback on macOS, where
# --- upstream publishes no per-asset checksum file to pin against.
hadolint_bin=""
case "$os-$arch" in
  Linux-x86_64)
    fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
      "$CACHE/hadolint" c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507
    chmod +x "$CACHE/hadolint"; hadolint_bin="$CACHE/hadolint" ;;
  Linux-aarch64|Linux-arm64)
    fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-arm64" \
      "$CACHE/hadolint" f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d
    chmod +x "$CACHE/hadolint"; hadolint_bin="$CACHE/hadolint" ;;
  Darwin-*)
    if command -v hadolint >/dev/null; then
      hadolint_bin=hadolint
      have="$(hadolint --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      [ "$have" = "$HADOLINT_VERSION" ] || \
        printf 'note: PATH hadolint is %s, CI runs %s (brew upgrade hadolint)\n' "$have" "$HADOLINT_VERSION"
    else
      die "hadolint not found -- brew install hadolint (CI runs $HADOLINT_VERSION)"
    fi ;;
  *) die "unsupported platform $os-$arch" ;;
esac

# --- actionlint: pinned on all four platforms.
case "$os-$arch" in
  Linux-x86_64)  al_asset=linux_amd64  al_sum=f4c76b71db5755a713e6055cbb0857ed07e103e028bda117817660ebadb4386f ;;
  Linux-aarch64|Linux-arm64) al_asset=linux_arm64 al_sum=cd3dfe5f66887ec6b987752d8d9614e59fd22f39415c5ad9f28374623f41773a ;;
  Darwin-x86_64) al_asset=darwin_amd64 al_sum=16782c41f2af264db80f855ee5d09164ca98fc78edf3bcd0f46eecff279682ba ;;
  Darwin-arm64)  al_asset=darwin_arm64 al_sum=004ca87b367b37f4d75c55ab6cf80f9b8c043adbfbd440f31c604d417939c442 ;;
esac
if [ ! -x "$CACHE/actionlint" ]; then
  fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${al_asset}.tar.gz" \
    "$CACHE/actionlint.tgz" "$al_sum"
  tar -xzf "$CACHE/actionlint.tgz" -C "$CACHE" actionlint
  rm -f "$CACHE/actionlint.tgz"
fi

command -v shellcheck >/dev/null || die "shellcheck not found (apt-get install shellcheck / brew install shellcheck)"
command -v jq >/dev/null || die "jq not found (apt-get install jq / brew install jq)"

# --- 1. shellcheck: what CI runs, plus this repo's own scripts.
note "shellcheck (test scripts + scripts/)"
shellcheck ./*/test.sh scripts/*.sh || fail=1

# --- 2. hadolint, exactly as the CI lint job invokes it.
note "hadolint $HADOLINT_VERSION (failure-threshold: warning)"
"$hadolint_bin" --failure-threshold warning ./*/Dockerfile.ci || fail=1

# --- 3. actionlint: workflow validity, including the workflow_call structure
# --- and shellcheck over every run: block.
note "actionlint $ACTIONLINT_VERSION"
"$CACHE/actionlint" || fail=1

# --- 4. images.json validation -- the same checks as the CI lint job, kept in
# --- sync by hand: if you change one, change the other.
note "images.json cross-check"
{
  jq -e 'type == "array" and length > 0 and
         all(.[]; (.image | test("^ci-[a-z0-9]+$")) and
                  (.version | length > 0) and
                  (.mirror | length > 0) and
                  (.upstream | length > 0))' \
    .github/images.json >/dev/null
  for img in $(jq -r '.[].image' .github/images.json); do
    test -f "$img/Dockerfile.ci" || { echo "error: $img in images.json but $img/Dockerfile.ci missing"; exit 1; }
    test -x "$img/test.sh"       || { echo "error: $img/test.sh missing or not executable"; exit 1; }
  done
  for d in ci-*/; do
    jq -e --arg i "${d%/}" 'any(.[]; .image == $i)' .github/images.json >/dev/null \
      || { echo "error: directory $d has no images.json entry"; exit 1; }
  done

  # kubectl is pinned in two Dockerfiles -- ci-tools and ci-cloud -- so a
  # cluster deploy behaves identically whichever image runs it. Nothing made
  # that true except a comment, so assert it: a bump that updates one and not
  # the other is caught here rather than by someone debugging a version skew.
  for key in KUBECTL_VERSION KUBECTL_SHA256_AMD64 KUBECTL_SHA256_ARM64; do
    # `|| true` because this block runs with errexit suppressed (it sits inside
    # `{ ... } || fail=1`), so a non-matching grep must not look like a match.
    a=$(grep -m1 "^ARG $key=" ci-tools/Dockerfile.ci || true)
    b=$(grep -m1 "^ARG $key=" ci-cloud/Dockerfile.ci || true)
    # An ARG missing from BOTH files would otherwise compare "" = "" and pass,
    # so a rename or deletion would silently disable this check.
    if [ -z "$a" ] || [ -z "$b" ]; then
      echo "error: $key not found in ci-tools and/or ci-cloud Dockerfile.ci"
      exit 1
    fi
    if [ "$a" != "$b" ]; then
      echo "error: $key differs between ci-tools and ci-cloud"
      echo "  ci-tools: $a"
      echo "  ci-cloud: $b"
      exit 1
    fi
  done
} || fail=1

# --- 5. zizmor, best-effort and non-gating -- the same posture as CI, where
# --- its findings surface through code scanning rather than a red job.
note "zizmor (best-effort, reported not gating)"
if command -v zizmor >/dev/null; then
  zizmor --no-progress --offline . || true
elif command -v uvx >/dev/null; then
  uvx zizmor --no-progress --offline . || true
else
  echo "zizmor not found -- skipped (pip install zizmor to run the workflow audit locally)"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "LINT FAILED -- one or more gating checks above reported problems"
  exit 1
fi
echo "LINT PASSED -- this is the CI lint job; a green run here is a green run there"
