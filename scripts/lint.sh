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
# change plus its checksums below, both copied from the vendor's own published
# checksums file, and nothing else in the repository has to move with it.
#
# Neither is tracked by Dependabot -- they are plain shell variables, not action
# pins -- but both are in scripts/check-pins.sh, and scripts/bump-pins.sh moves
# each version together with its checksums below. That is why every digest is a
# named variable in `KEY=value` form next to its version, rather than inline in
# the download call: one spelling, rewritten by one rule, the same as a
# Dockerfile `ARG`.
HADOLINT_VERSION=2.15.1
HADOLINT_SHA256_LINUX_X86_64=c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507
HADOLINT_SHA256_LINUX_ARM64=f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d
HADOLINT_SHA256_MACOS_ARM64=5c09f3213f8e40406abe048233d985eebef336d4a6a20021be47fadb6cf480a2
HADOLINT_SHA256_MACOS_X86_64=ffe9bb18b23d5ed1eae50237aecdbb523d016e96da0bd4e7aa432040acfc3fde
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256_LINUX_AMD64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ACTIONLINT_SHA256_LINUX_ARM64=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
ACTIONLINT_SHA256_DARWIN_AMD64=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
ACTIONLINT_SHA256_DARWIN_ARM64=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f

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

# --- hadolint: pinned release binary on every platform.
#
# These digests are the vendor's, not ours. hadolint publishes
#   releases/download/v<version>/checksums.sha256
# covering all five assets, so a bump means copying two lines out of that file
# rather than hashing a download and hoping it was the right one. This script
# used to say upstream published nothing and carried self-observed hashes
# instead; that was wrong. A hash you computed from your own download attests
# only to what you happened to fetch -- if the fetch was tampered with, you
# faithfully record the tampered digest and every later check passes.
#
# macOS was a PATH fallback for the same mistaken reason, with a warning when
# brew's hadolint differed from the pinned one. The vendor publishes macOS
# digests too, so it now gets the same pinned, verified binary as Linux and the
# skew it warned about cannot happen.
hadolint_bin=""
case "$os-$arch" in
  Linux-x86_64)
    fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
      "$CACHE/hadolint" "$HADOLINT_SHA256_LINUX_X86_64" ;;
  Linux-aarch64|Linux-arm64)
    fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-arm64" \
      "$CACHE/hadolint" "$HADOLINT_SHA256_LINUX_ARM64" ;;
  Darwin-arm64)
    fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-macos-arm64" \
      "$CACHE/hadolint" "$HADOLINT_SHA256_MACOS_ARM64" ;;
  Darwin-x86_64)
    fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-macos-x86_64" \
      "$CACHE/hadolint" "$HADOLINT_SHA256_MACOS_X86_64" ;;
  *) die "unsupported platform $os-$arch" ;;
esac
chmod +x "$CACHE/hadolint"; hadolint_bin="$CACHE/hadolint"

# --- actionlint: pinned on all four platforms.
case "$os-$arch" in
  Linux-x86_64)  al_asset=linux_amd64  al_sum="$ACTIONLINT_SHA256_LINUX_AMD64" ;;
  Linux-aarch64|Linux-arm64) al_asset=linux_arm64 al_sum="$ACTIONLINT_SHA256_LINUX_ARM64" ;;
  Darwin-x86_64) al_asset=darwin_amd64 al_sum="$ACTIONLINT_SHA256_DARWIN_AMD64" ;;
  Darwin-arm64)  al_asset=darwin_arm64 al_sum="$ACTIONLINT_SHA256_DARWIN_ARM64" ;;
esac
# Cached per version. A bare `.lint-cache/actionlint` survived a version bump:
# the binary was only fetched when absent, so after a bump this script kept
# running the old engine locally while announcing the new version number.
actionlint_bin="$CACHE/actionlint-$ACTIONLINT_VERSION"
if [ ! -x "$actionlint_bin" ]; then
  fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${al_asset}.tar.gz" \
    "$CACHE/actionlint.tgz" "$al_sum"
  tar -xzf "$CACHE/actionlint.tgz" -C "$CACHE" actionlint
  mv "$CACHE/actionlint" "$actionlint_bin"
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
"$actionlint_bin" || fail=1

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

  # Composer is pinned in both PHP images -- ci-php84 and ci-php85 -- and
  # scripts/check-pins.sh reads only ci-php84's copy. Same reasoning as kubectl
  # above: assert the two agree, so the pin-drift report covers both and a bump
  # that moves one cannot leave the other behind unnoticed.
  for key in COMPOSER_VERSION COMPOSER_SHA256; do
    a=$(grep -m1 "^ARG $key=" ci-php84/Dockerfile.ci || true)
    b=$(grep -m1 "^ARG $key=" ci-php85/Dockerfile.ci || true)
    if [ -z "$a" ] || [ -z "$b" ]; then
      echo "error: $key not found in ci-php84 and/or ci-php85 Dockerfile.ci"
      exit 1
    fi
    if [ "$a" != "$b" ]; then
      echo "error: $key differs between ci-php84 and ci-php85"
      echo "  ci-php84: $a"
      echo "  ci-php85: $b"
      exit 1
    fi
  done
} || fail=1

# --- 5. vuln-exceptions.json: the vulnerability gate's expiring, per-image,
# --- per-CVE exceptions (docs/adr/0006). build-image.yml and
# --- scripts/alerts-report.sh each re-check the fields they depend on and
# --- refuse to run on a malformed entry; this is where a bad entry is caught
# --- before it reaches either, and where the rules that only matter at review
# --- time are enforced: a real image, an id in the form Trivy prints, no
# --- duplicates, and no expiry more than 90 days out, so an exception cannot
# --- be parked and forgotten. Renewing one is a new PR with a new date.
# ---
# --- Every entry must also be narrowed to `paths` (literal Trivy paths: no
# --- leading "/", no glob characters) and/or `purls` (pkg:<type>/<name>@<version>
# --- as Trivy prints it). An entry with neither would excuse its id in every
# --- package of the image, which is not what an exception is for.
# ---
# --- An entry that has already expired is a warning, not a failure: the gate
# --- itself turns that image red again, which is the intended signal, and an
# --- expiry date passing must not break lint for every unrelated PR. "Expired"
# --- starts ON the `expires` date, the same boundary Trivy applies to the
# --- `expired_at` it is turned into.
# ---
# --- A subshell rather than the { } used above, so an `exit 1` here fails
# --- this check without skipping the rest of the battery.
note "vuln-exceptions.json"
(
  exc=.github/vuln-exceptions.json
  today=$(date -u +%Y-%m-%d)
  # errexit is off in here (this is the left side of `||`), so every jq call
  # checks its own status: a file that is not JSON must fail, not pass empty.
  if ! jq -e 'type == "array"' "$exc" >/dev/null; then
    echo "error: $exc is not a JSON array"
    exit 1
  fi
  if ! problems=$(jq -r --slurpfile images .github/images.json --arg today "$today" '
      def text: type == "string" and length > 0;
      def valid_date: type == "string"
        and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
        and ((try (strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch null) == .);
      ($images[0] | map(.image)) as $known
      | ($today | strptime("%Y-%m-%d") | mktime + 90 * 86400 | strftime("%Y-%m-%d")) as $limit
      | to_entries[]
      | .key as $n | .value as $e
      | "entry \($n) (\($e.image? // "?") \($e.id? // "?"))" as $at
      | if ($e | type) != "object" then "\($at): not an object"
        else
          ( ["image", "id", "package", "installed", "reason", "upstream", "expires"][]
            | select(($e[.] | text) | not) | "\($at): missing or empty \"\(.)\"" ),
          ( select(($e.image | text) and (any($known[]; . == $e.image) | not))
            | "\($at): image is not in .github/images.json" ),
          ( select(($e.id | text)
                   and ($e.id | test("^(CVE-[0-9]{4}-[0-9]+|GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4})$") | not))
            | "\($at): id is not a CVE-YYYY-N or GHSA-xxxx-xxxx-xxxx id as Trivy prints it" ),
          ( select(($e.expires | text) and ($e.expires | valid_date | not))
            | "\($at): expires \($e.expires) is not a valid YYYY-MM-DD date" ),
          ( select(($e.expires | valid_date) and $e.expires > $limit)
            | "\($at): expires \($e.expires) is more than 90 days after today (\($today)); the latest allowed is \($limit)" ),
          ( select(($e | has("paths") | not) and ($e | has("purls") | not))
            | "\($at): needs \"paths\" or \"purls\" (or both); an entry with neither would excuse the id in every package of the image" ),
          ( select($e | has("paths"))
            | select(($e.paths | type) != "array" or ($e.paths | length) == 0
                     or any($e.paths[]; text | not))
            | "\($at): paths, when present, must be a non-empty array of non-empty strings" ),
          ( select(($e.paths | type) == "array")
            | $e.paths[] | strings
            | select(startswith("/") or test("[*?\\[]"))
            | "\($at): path \(tojson) must be written as Trivy reports it: no leading \"/\" and no glob characters (*, ?, [)" ),
          ( select($e | has("purls"))
            | select(($e.purls | type) != "array" or ($e.purls | length) == 0
                     or any($e.purls[]; text | not))
            | "\($at): purls, when present, must be a non-empty array of non-empty strings" ),
          ( select(($e.purls | type) == "array")
            | $e.purls[] | strings
            | select(test("^pkg:[a-z]+/[^@\\s]+@[^\\s]+$") | not)
            | "\($at): purl \(tojson) is not pkg:<type>/<name>@<version>, the form Trivy prints (e.g. pkg:pypi/msgpack@1.1.2)" )
        end
    ' "$exc"); then
    echo "error: could not check $exc"
    exit 1
  fi
  if ! dups=$(jq -r '[.[] | select(type == "object") | "\(.image) \(.id)"] | group_by(.)[]
                     | select(length > 1) | "\(.[0]) appears \(length) times"' "$exc"); then
    echo "error: could not check $exc for duplicates"
    exit 1
  fi
  if [ -n "$dups" ]; then
    while IFS= read -r line; do
      problems="${problems}${problems:+$'\n'}duplicate (image, id): $line"
    done <<< "$dups"
  fi
  if [ -n "$problems" ]; then
    while IFS= read -r line; do echo "error: $exc: $line"; done <<< "$problems"
    exit 1
  fi
  if ! expired=$(jq -r --arg today "$today" \
      '.[] | select(.expires <= $today) | "\(.image) \(.id) (expires \(.expires))"' "$exc"); then
    echo "error: could not check $exc for expired entries"
    exit 1
  fi
  if [ -n "$expired" ]; then
    while IFS= read -r line; do
      echo "warning: $exc: expired, so the gate fails on it again -- remove or renew it: $line"
    done <<< "$expired"
  fi
  echo "$(jq length "$exc") exception(s) checked"
) || fail=1

# --- 6. scripts/bump-pins.sh, tested offline against fixtures in the vendors'
# --- own file formats. It writes the checksums an automated bump can merge
# --- without a human reading them (docs/adr/0007), so a regression in it has
# --- to fail here, before it writes a wrong pin, not in the bump PR after.
# --- The same suite drives scripts/pin-bump-prs.sh against a local origin,
# --- since what it pushes over, dispatches and auto-merges is just as unwatched.
note "bump-pins and pin-bump-prs offline tests"
if ./scripts/test-bump-pins.sh > "$CACHE/test-bump-pins.log" 2>&1; then
  tail -1 "$CACHE/test-bump-pins.log"
else
  cat "$CACHE/test-bump-pins.log"; fail=1
fi

# --- 7. zizmor, best-effort and non-gating -- the same posture as CI, where
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
