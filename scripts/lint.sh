#!/usr/bin/env bash
# The CI lint battery, locally -- the same checks the `lint` job runs, on the
# same engine versions, so local-clean means CI-lint-clean:
#
#   make lint
#
# Engines are downloaded once into .lint-cache/ (git-ignored) as pinned,
# checksum-verified release binaries -- the same pattern as the ci-tools
# binaries, Composer, and gitleaks in security.yml. hadolint is pinned to the
# exact version hadolint-action bundles in CI, which is the whole point:
# a version drift between local and CI is how "it passed on my machine" happens.
#
# zizmor runs best-effort at the end when available (pip install zizmor, or
# uv). Its findings are reported, not gating -- the same posture as CI.
set -euo pipefail

HADOLINT_VERSION=2.14.0
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
      "$CACHE/hadolint" 6bf226944684f56c84dd014e8b979d27425c0148f61b3bd99bcc6f39e9dc5a47
    chmod +x "$CACHE/hadolint"; hadolint_bin="$CACHE/hadolint" ;;
  Linux-aarch64|Linux-arm64)
    fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-arm64" \
      "$CACHE/hadolint" 331f1d3511b84a4f1e3d18d52fec284723e4019552f4f47b19322a53ce9a40ed
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
    a=$(grep -m1 "^ARG $key=" ci-tools/Dockerfile.ci)
    b=$(grep -m1 "^ARG $key=" ci-cloud/Dockerfile.ci)
    [ "$a" = "$b" ] || {
      echo "error: $key differs between ci-tools and ci-cloud"
      echo "  ci-tools: $a"
      echo "  ci-cloud: $b"
      exit 1
    }
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
echo "LINT PASSED -- same engines and thresholds as the CI lint job"
