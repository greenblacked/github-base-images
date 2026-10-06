#!/usr/bin/env bash
# Offline tests for scripts/bump-pins.sh, and for scripts/pin-bump-prs.sh on top
# of it (case 6). No network: every vendor response is a fixture written below,
# in the vendor's real file format, and bump-pins.sh refuses to fall through to
# the network for a URL that has no fixture. The pin-bump-prs.sh cases push to a
# local bare repository and answer GitHub from canned files and a fake gh.
#
#   ./scripts/test-bump-pins.sh        # run by scripts/lint.sh, so CI runs it too
#
# Each case runs against a scratch copy of the files bump-pins.sh edits, with
# the pins first forced to a fixed baseline -- so the tests do not start
# failing the day the real pins move past the fixture versions.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/.." && pwd)
bump="$here/bump-pins.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# --- fixtures ----------------------------------------------------------------
fx="$work/fixtures"
mkdir -p "$fx"
: > "$fx/urls"
# serve URL FILE -- FILE's content (written by the caller) answers URL.
serve() { printf '%s %s\n' "$1" "$2" >> "$fx/urls"; }
# A stand-in vendor digest: distinct per label, and plainly not a real one.
fake() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
gh_release() { # REPO TAG DATE
  local f; f="rel-$(printf '%s' "$1-$2" | tr '/' '_').json"
  printf '{"tag_name":"%s","published_at":"%s"}\n' "$2" "$3" > "$fx/$f"
  serve "https://api.github.com/repos/$1/releases/tags/$2" "$f"
}
G=https://github.com
OLD='2026-09-01T12:00:00Z'      # 27 days before NOW: past the cooldown
FRESH='2026-09-26T09:30:00.123Z' # 2 days before NOW: inside it
NOW=1790553600                  # 2026-09-28T00:00:00Z

# trivy 0.75.0: an ordinary auto bump from a goreleaser-style checksums file.
cat > "$fx/trivy.txt" <<EOF
$(fake trivy-32)  trivy_0.75.0_Linux-32bit.tar.gz
$(fake trivy-amd64)  trivy_0.75.0_Linux-64bit.tar.gz
$(fake trivy-arm)  trivy_0.75.0_Linux-ARM.tar.gz
$(fake trivy-arm64)  trivy_0.75.0_Linux-ARM64.tar.gz
EOF
serve "$G/aquasecurity/trivy/releases/download/v0.75.0/trivy_0.75.0_checksums.txt" trivy.txt
gh_release aquasecurity/trivy v0.75.0 "$OLD"

# kubectl 1.38.0: one bare-hash file per artifact, pinned in two images.
printf '%s' "$(fake kubectl-amd64)" > "$fx/kubectl-amd64"   # no trailing newline, as dl.k8s.io serves it
printf '%s\n' "$(fake kubectl-arm64)" > "$fx/kubectl-arm64"
serve "https://dl.k8s.io/release/v1.38.0/bin/linux/amd64/kubectl.sha256" kubectl-amd64
serve "https://dl.k8s.io/release/v1.38.0/bin/linux/arm64/kubectl.sha256" kubectl-arm64
gh_release kubernetes/kubernetes v1.38.0 "$OLD"

# syft 2.0.0: checksums published, but a major version -> review.
cat > "$fx/syft.txt" <<EOF
$(fake syft-amd64)  syft_2.0.0_linux_amd64.tar.gz
$(fake syft-arm64)  syft_2.0.0_linux_arm64.tar.gz
EOF
serve "$G/anchore/syft/releases/download/v2.0.0/syft_2.0.0_checksums.txt" syft.txt
gh_release anchore/syft v2.0.0 "$OLD"

# docker 29.9.0: no vendor checksum -> review, and the artifacts must exist.
echo present > "$fx/present"
serve "https://download.docker.com/linux/static/stable/x86_64/docker-29.9.0.tgz" present
serve "https://download.docker.com/linux/static/stable/aarch64/docker-29.9.0.tgz" present

# grype 0.120.0: the checksums file 404s -> this unit fails, others carry on.
serve "$G/anchore/grype/releases/download/v0.120.0/grype_0.120.0_checksums.txt" @404
gh_release anchore/grype v0.120.0 "$OLD"

# migrate 4.20.2: succeeds alongside grype's failure, in a different file.
cat > "$fx/migrate.txt" <<EOF
$(fake migrate-amd64)  migrate.linux-amd64.tar.gz
$(fake migrate-arm64)  migrate.linux-arm64.tar.gz
EOF
serve "$G/golang-migrate/migrate/releases/download/v4.20.2/sha256sum.txt" migrate.txt
gh_release golang-migrate/migrate v4.20.2 "$OLD"

# gitleaks 8.31.0: paired across ci-security and security.yml.
cat > "$fx/gitleaks.txt" <<EOF
$(fake gitleaks-darwin)  gitleaks_8.31.0_darwin_arm64.tar.gz
$(fake gitleaks-arm64)  gitleaks_8.31.0_linux_arm64.tar.gz
$(fake gitleaks-x64)  gitleaks_8.31.0_linux_x64.tar.gz
EOF
serve "$G/gitleaks/gitleaks/releases/download/v8.31.0/gitleaks_8.31.0_checksums.txt" gitleaks.txt
gh_release gitleaks/gitleaks v8.31.0 "$OLD"

# cosign 3.2.0: released two days ago -> deferred, nothing edited.
gh_release sigstore/cosign v3.2.0 "$FRESH"

# hadolint 2.15.2: `*` binary-mode markers and CRLF line ends, into lint.sh.
{
  printf '%s *hadolint-linux-arm64\r\n' "$(fake hl-linux-arm64)"
  printf '%s *hadolint-linux-x86_64\r\n' "$(fake hl-linux-x86_64)"
  printf '%s *hadolint-macos-arm64\r\n' "$(fake hl-macos-arm64)"
  printf '%s *hadolint-macos-x86_64\r\n' "$(fake hl-macos-x86_64)"
} > "$fx/hadolint.txt"
serve "$G/hadolint/hadolint/releases/download/v2.15.2/checksums.sha256" hadolint.txt
gh_release hadolint/hadolint v2.15.2 "$OLD"

# npm 12.2.0: registry integrity, both node images.
cat > "$fx/npm.json" <<'EOF'
{"dist-tags":{"latest":"12.2.0"},
 "versions":{"12.1.0":{"dist":{"integrity":"sha512-old"}},"12.2.0":{"dist":{"integrity":"sha512-Zm9vYmFy"}}},
 "time":{"12.1.0":"2026-08-01T00:00:00.000Z","12.2.0":"2026-09-10T08:00:00.000Z"}}
EOF
serve "https://registry.npmjs.org/npm" npm.json

# composer 2.10.4: getcomposer.org's sha256sum file, both PHP images.
printf '%s  composer.phar\n' "$(fake composer)" > "$fx/composer.txt"
serve "https://getcomposer.org/download/2.10.4/composer.phar.sha256sum" composer.txt
gh_release composer/composer 2.10.4 "$OLD"

# osv-scanner 2.6.1: the file exists but lacks the one asset we need.
printf '%s  osv-scanner_darwin_arm64\n' "$(fake osv-darwin)" > "$fx/osv.txt"
serve "$G/google/osv-scanner/releases/download/v2.6.1/osv-scanner_SHA256SUMS" osv.txt
gh_release google/osv-scanner v2.6.1 "$OLD"

# json 2.20.0: rubygems sha, with a -java build of the same number beside it.
cat > "$fx/json.json" <<EOF
[{"number":"2.20.0","platform":"java","prerelease":false,"created_at":"2026-09-05T00:00:00.000Z","sha":"$(fake json-java)"},
 {"number":"2.20.0","platform":"ruby","prerelease":false,"created_at":"2026-09-05T00:00:00.000Z","sha":"$(fake json-ruby)"}]
EOF
serve "https://rubygems.org/api/v1/versions/json.json" json.json

# --- a scratch tree with pins at a fixed baseline -------------------------------
# The images that carry a runtime's shared pins are read from images.json, the
# way bump-pins.sh and check-pins.sh read them, so an image the lifecycle
# workflow adds or retires changes nothing here. carriers KEY -> their
# Dockerfiles, one per line.
carriers() {
  local img
  for img in $(jq -r '.[].image' "$repo/.github/images.json"); do
    grep -q "^ARG $1=" "$repo/$img/Dockerfile.ci" && printf '%s\n' "$img/Dockerfile.ci"
  done
  return 0
}
NODE_FILES=$(carriers NPM_VERSION); PHP_FILES=$(carriers COMPOSER_VERSION); JSON_FILES=$(carriers JSON_VERSION)
if [ -z "$NODE_FILES" ] || [ -z "$PHP_FILES" ]; then
  echo "no image pins npm or Composer; these tests need one of each" >&2; exit 1
fi
# shellcheck disable=SC2206  # one path per word
files=(
  ci-tools/Dockerfile.ci ci-cloud/Dockerfile.ci ci-security/Dockerfile.ci ci-db/Dockerfile.ci
  $NODE_FILES $PHP_FILES $JSON_FILES .github/workflows/security.yml .github/workflows/build-image.yml
  scripts/lint.sh .github/images.json
)
force() { # FILE KEY VALUE -- set a baseline, whichever spelling the pin uses
  # Not `sed -i`, whose syntax differs between GNU and BSD sed; cat keeps the mode.
  sed -E "s/^(ARG )?($2)=[^[:space:]]*/\\1\\2=$3/; s/^([[:space:]]+$2:[[:space:]]+)[^[:space:]]*/\\1$3/" "$1" > "$1.tmp"
  cat "$1.tmp" > "$1"; rm -f "$1.tmp"
}
new_tree() {
  local t="$work/$1" f
  rm -rf "$t"; mkdir -p "$t"
  for f in "${files[@]}"; do mkdir -p "$t/$(dirname "$f")"; cp -p "$repo/$f" "$t/$f"; done
  force "$t/ci-security/Dockerfile.ci" TRIVY_VERSION 0.74.0
  force "$t/ci-security/Dockerfile.ci" SYFT_VERSION 1.52.0
  force "$t/ci-security/Dockerfile.ci" GRYPE_VERSION 0.119.0
  force "$t/ci-security/Dockerfile.ci" COSIGN_VERSION 3.1.3
  force "$t/ci-security/Dockerfile.ci" GITLEAKS_VERSION 8.30.1
  force "$t/.github/workflows/security.yml" GITLEAKS_VERSION 8.30.1
  force "$t/ci-tools/Dockerfile.ci" KUBECTL_VERSION 1.37.0
  force "$t/ci-cloud/Dockerfile.ci" KUBECTL_VERSION 1.37.0
  force "$t/ci-tools/Dockerfile.ci" DOCKER_VERSION 29.8.1
  force "$t/ci-db/Dockerfile.ci" MIGRATE_VERSION 4.20.1
  force "$t/scripts/lint.sh" HADOLINT_VERSION 2.15.1
  for f in $NODE_FILES; do force "$t/$f" NPM_VERSION 12.1.0; done
  for f in $PHP_FILES; do force "$t/$f" COMPOSER_VERSION 2.10.3; done
  force "$t/.github/workflows/build-image.yml" OSV_SCANNER_VERSION 2.6.0
  for f in $JSON_FILES; do force "$t/$f" JSON_VERSION 2.19.9; done
  printf '%s' "$t"
}
pin() { # FILE KEY
  grep -m1 -E "^(ARG )?$2=|^[[:space:]]+$2:[[:space:]]" "$1" | sed -E "s/^ARG //;s/^$2=//;s/^[[:space:]]+$2:[[:space:]]*//"
}
expect_pin() { # TREE FILE KEY VALUE
  local got; got=$(pin "$1/$2" "$3")
  if [ "$got" = "$4" ]; then ok "$2 $3 = $4"; else bad "$2 $3: expected $4, got $got"; fi
}
field() { # RESULTS UNIT FIELD
  jq -r --arg u "$2" --arg f "$3" '.[] | select(.unit == $u) | .[$f] // "null"' "$1"
}
expect_field() { # RESULTS UNIT FIELD VALUE
  local got; got=$(field "$1" "$2" "$3")
  if [ "$got" = "$4" ]; then ok "$2 $3 = $4"; else bad "$2 $3: expected $4, got $got"; fi
}
# The two parity checks scripts/lint.sh gates on, run over the scratch tree.
parity() { # TREE A B KEY...
  local t="$1" a="$2" b="$3"; shift 3
  local key x y
  for key in "$@"; do
    x=$(grep -m1 "^ARG $key=" "$t/$a" || true); y=$(grep -m1 "^ARG $key=" "$t/$b" || true)
    [ -n "$x" ] && [ "$x" = "$y" ] || return 1
  done
}
changed_files() { # TREE SNAPSHOT
  (cd "$1" && find . -type f | sort | while read -r f; do cmp -s "$f" "$2/$f" || printf '%s\n' "${f#./}"; done)
}

drift() { # rows as "tool latest" -> a check-pins JSON report on stdout
  local rows="" tool latest
  while read -r tool latest; do
    rows="$rows$(jq -nc --arg t "$tool" --arg l "$latest" '{tool:$t, pinned:"x", latest:$l, file:"x", key:"x", state:"behind"}')"
  done
  printf '%s' "$rows" | jq -s '{drift: length, failed: 0, tools: .}'
}

export BUMP_PINS_FIXTURES="$fx" BUMP_PINS_NOW="$NOW"
unset GITHUB_TOKEN

# --- case 1: one run over a mixed drift report -----------------------------------
echo "case 1: a mixed drift report"
t=$(new_tree one)
snap="$work/one.snap"; cp -a "$t" "$snap"
drift > "$work/drift1.json" <<'EOF'
trivy 0.75.0
kubectl 1.38.0
syft 2.0.0
docker 29.9.0
grype 0.120.0
migrate 4.20.2
gitleaks 8.31.0
gitleaks-workflow 8.31.0
cosign 3.2.0
hadolint 2.15.2
npm 12.2.0
composer 2.10.4
osv-scanner 2.6.1
json 2.20.0
EOF
rc=0
"$bump" --root "$t" --drift "$work/drift1.json" --format json --quiet > "$work/r1.json" 2> "$work/r1.err" || rc=$?
check "exit 1, because grype and osv-scanner failed" [ "$rc" -eq 1 ]
check "one result per unit, gitleaks rows merged" [ "$(jq length "$work/r1.json")" -eq 13 ]

echo " normal bump (trivy)"
expect_field "$work/r1.json" trivy status bumped
expect_field "$work/r1.json" trivy class auto
expect_pin "$t" ci-security/Dockerfile.ci TRIVY_VERSION 0.75.0
expect_pin "$t" ci-security/Dockerfile.ci TRIVY_SHA256_AMD64 "$(fake trivy-amd64)"
expect_pin "$t" ci-security/Dockerfile.ci TRIVY_SHA256_ARM64 "$(fake trivy-arm64)"

echo " paired bump (kubectl in ci-tools and ci-cloud)"
expect_field "$work/r1.json" kubectl class auto
for f in ci-tools/Dockerfile.ci ci-cloud/Dockerfile.ci; do
  expect_pin "$t" "$f" KUBECTL_VERSION 1.38.0
  expect_pin "$t" "$f" KUBECTL_SHA256_AMD64 "$(fake kubectl-amd64)"
  expect_pin "$t" "$f" KUBECTL_SHA256_ARM64 "$(fake kubectl-arm64)"
done
check "lint.sh kubectl parity holds" parity "$t" ci-tools/Dockerfile.ci ci-cloud/Dockerfile.ci KUBECTL_VERSION KUBECTL_SHA256_AMD64 KUBECTL_SHA256_ARM64
for f in $PHP_FILES; do
  expect_pin "$t" "$f" COMPOSER_VERSION 2.10.4
  expect_pin "$t" "$f" COMPOSER_SHA256 "$(fake composer)"
done
check "every PHP image carries Composer, so the parity above is not vacuous" [ "$(printf '%s\n' "$PHP_FILES" | wc -l)" -ge 1 ]
expect_field "$work/r1.json" composer class auto

echo " paired bump (gitleaks in ci-security and security.yml)"
expect_pin "$t" ci-security/Dockerfile.ci GITLEAKS_VERSION 8.31.0
expect_pin "$t" ci-security/Dockerfile.ci GITLEAKS_SHA256_AMD64 "$(fake gitleaks-x64)"
expect_pin "$t" ci-security/Dockerfile.ci GITLEAKS_SHA256_ARM64 "$(fake gitleaks-arm64)"
expect_pin "$t" .github/workflows/security.yml GITLEAKS_VERSION 8.31.0
expect_pin "$t" .github/workflows/security.yml GITLEAKS_SHA256 "$(fake gitleaks-x64)"

echo " major version -> review (syft); a minor from the registry -> auto (json)"
expect_field "$work/r1.json" syft status bumped
expect_field "$work/r1.json" syft class review
expect_pin "$t" ci-security/Dockerfile.ci SYFT_SHA256_AMD64 "$(fake syft-amd64)"
if [ -n "$JSON_FILES" ]; then
  expect_field "$work/r1.json" json class auto
  for f in $JSON_FILES; do expect_pin "$t" "$f" JSON_VERSION 2.20.0; done
else
  # No image replaces the json gem any more (it was ci-ruby40's workaround):
  # the unit has no pin to move, and says so rather than inventing one.
  expect_field "$work/r1.json" json status error
fi

echo " no vendor checksum -> review (docker)"
expect_field "$work/r1.json" docker class review
expect_pin "$t" ci-tools/Dockerfile.ci DOCKER_VERSION 29.9.0

echo " registry integrity (npm, both images) and lint.sh digests (hadolint, CRLF + '*')"
expect_field "$work/r1.json" npm class auto
for f in $NODE_FILES; do expect_pin "$t" "$f" NPM_VERSION 12.2.0; done
expect_pin "$t" scripts/lint.sh HADOLINT_VERSION 2.15.2
expect_pin "$t" scripts/lint.sh HADOLINT_SHA256_LINUX_X86_64 "$(fake hl-linux-x86_64)"
expect_pin "$t" scripts/lint.sh HADOLINT_SHA256_MACOS_ARM64 "$(fake hl-macos-arm64)"
check "lint.sh is still executable" [ -x "$t/scripts/lint.sh" ]
check "lint.sh still parses" bash -n "$t/scripts/lint.sh"

echo " cooldown (cosign released 2 days ago) -> deferred, untouched"
expect_field "$work/r1.json" cosign status deferred
expect_pin "$t" ci-security/Dockerfile.ci COSIGN_VERSION 3.1.3

echo " resolver failure for one unit while others succeed"
expect_field "$work/r1.json" grype status error
expect_pin "$t" ci-security/Dockerfile.ci GRYPE_VERSION 0.119.0
check "grype checksum lines untouched" \
  [ "$(grep '^ARG GRYPE_' "$t/ci-security/Dockerfile.ci")" = "$(grep '^ARG GRYPE_' "$snap/ci-security/Dockerfile.ci")" ]
expect_field "$work/r1.json" migrate status bumped
expect_pin "$t" ci-db/Dockerfile.ci MIGRATE_SHA256_ARM64 "$(fake migrate-arm64)"
expect_field "$work/r1.json" osv-scanner status error
check "a checksum file missing the asset leaves build-image.yml byte-identical" \
  cmp -s "$t/.github/workflows/build-image.yml" "$snap/.github/workflows/build-image.yml"

echo " nothing outside the expected files changed"
# shellcheck disable=SC2086  # one path per word
expected=$(printf '%s\n' .github/workflows/security.yml ci-cloud/Dockerfile.ci ci-db/Dockerfile.ci \
  $NODE_FILES $PHP_FILES $JSON_FILES ci-security/Dockerfile.ci ci-tools/Dockerfile.ci scripts/lint.sh | sort)
check "changed files are exactly the bumped units' files" [ "$(changed_files "$t" "$snap")" = "$expected" ]
check "every changed line is a pin line" \
  bash -c "cd '$work' && diff -r one.snap one | grep -E '^[<>]' | grep -vE '^[<>] (ARG )?[A-Z0-9_]+=|^[<>] +[A-Z0-9_]+: ' | { ! grep -q .; }"

# --- case 2: re-running on the bumped tree is a no-op ------------------------------
echo "case 2: re-run on an already-bumped tree"
cp -a "$t" "$work/one.after"
drift > "$work/drift2.json" <<'EOF'
trivy 0.75.0
kubectl 1.38.0
syft 2.0.0
docker 29.9.0
migrate 4.20.2
gitleaks 8.31.0
hadolint 2.15.2
npm 12.2.0
composer 2.10.4
json 2.20.0
EOF
# Without an image that pins json, its unit has nothing to be current at.
if [ -z "$JSON_FILES" ]; then
  jq '.tools |= map(select(.tool != "json"))' "$work/drift2.json" > "$work/d2" && mv "$work/d2" "$work/drift2.json"
fi
rc=0
"$bump" --root "$t" --drift "$work/drift2.json" --format json --quiet > "$work/r2.json" 2>/dev/null || rc=$?
check "exit 0" [ "$rc" -eq 0 ]
check "every unit reports current" [ "$(jq '[.[] | select(.status != "current")] | length' "$work/r2.json")" -eq 0 ]
check "the tree is byte-identical" [ -z "$(changed_files "$t" "$work/one.after")" ]

# --- case 3: standalone, one unit, and the guard rails ----------------------------
echo "case 3: standalone --unit, and refusals"
t=$(new_tree three)
rc=0; "$bump" --root "$t" --unit kubectl --to 1.38.0 --format json --quiet > "$work/r3.json" 2>/dev/null || rc=$?
check "--unit kubectl --to 1.38.0 exits 0" [ "$rc" -eq 0 ]
check "and moves both copies" parity "$t" ci-tools/Dockerfile.ci ci-cloud/Dockerfile.ci KUBECTL_VERSION KUBECTL_SHA256_AMD64 KUBECTL_SHA256_ARM64
expect_pin "$t" ci-cloud/Dockerfile.ci KUBECTL_VERSION 1.38.0

cp -a "$t" "$work/three.snap"
rc=0; "$bump" --root "$t" --unit trivy --to 9.9.9 --quiet --format json > "$work/r3b.json" 2>"$work/r3b.err" || rc=$?
check "a URL with no fixture fails the unit instead of reaching the network" [ "$rc" -eq 1 ]
check "  and says why" grep -q 'no fixture for' "$work/r3b.err"
check "  and edits nothing" [ -z "$(changed_files "$t" "$work/three.snap")" ]

rc=0; "$bump" --root "$t" --unit kubectl --to 1.36.0 --quiet --format json >/dev/null 2>&1 || rc=$?
check "a target older than the pin is refused" [ "$rc" -eq 1 ]
rc=0; "$bump" --root "$t" --unit nosuchtool --to 1.0.0 >/dev/null 2>&1 || rc=$?
check "an unknown unit is a usage error" [ "$rc" -eq 2 ]
rc=0; "$bump" --root "$t" --drift "$work/drift1.json" --unit trivy >/dev/null 2>&1 || rc=$?
check "--drift with --unit is a usage error" [ "$rc" -eq 2 ]

echo "case 4: --plan lists units without editing"
t=$(new_tree four); cp -a "$t" "$work/four.snap"
rc=0; "$bump" --root "$t" --plan --drift "$work/drift1.json" > "$work/plan.jsonl" 2>/dev/null || rc=$?
check "exit 0" [ "$rc" -eq 0 ]
check "13 units, gitleaks once" [ "$(jq -s length "$work/plan.jsonl")" -eq 13 ]
check "no file touched" [ -z "$(changed_files "$t" "$work/four.snap")" ]
printf '{"drift":1,"failed":0,"tools":[{"tool":"brand-new-tool","pinned":"1","latest":"2","file":"x","key":"x","state":"behind"}]}' > "$work/drift4.json"
rc=0; "$bump" --root "$t" --plan --drift "$work/drift4.json" > "$work/plan4.jsonl" 2>/dev/null || rc=$?
plan4_status=$(jq -r .status "$work/plan4.jsonl" 2>/dev/null || true)
check "a tool check-pins knows but bump-pins does not is an error, not a skip" \
  [ "$rc:$plan4_status" = "1:error" ]

echo "case 5: checksum files in an unexpected shape fail the unit, not pick a line"
t=$(new_tree five); cp -a "$t" "$work/five.snap"
# trivy 0.75.1: the amd64 asset listed twice, with different digests.
cat > "$fx/trivy-dup.txt" <<EOF
$(fake trivy-dup-a)  trivy_0.75.1_Linux-64bit.tar.gz
$(fake trivy-arm64)  trivy_0.75.1_Linux-ARM64.tar.gz
$(fake trivy-dup-b)  trivy_0.75.1_Linux-64bit.tar.gz
EOF
serve "$G/aquasecurity/trivy/releases/download/v0.75.1/trivy_0.75.1_checksums.txt" trivy-dup.txt
gh_release aquasecurity/trivy v0.75.1 "$OLD"
rc=0; "$bump" --root "$t" --unit trivy --to 0.75.1 --quiet --format json > "$work/r5a.json" 2> "$work/r5a.err" || rc=$?
check "an asset listed twice is an error (exit 1), not the first match" [ "$rc:$(field "$work/r5a.json" trivy status)" = "1:error" ]
check "  and says it found 2" grep -q 'found 2' "$work/r5a.err"
# trivy 0.75.2: the amd64 line has a third field, and a well-formed duplicate
# below it that a lenient parser would take.
cat > "$fx/trivy-3f.txt" <<EOF
$(fake trivy-3f-a)  trivy_0.75.2_Linux-64bit.tar.gz  extra
$(fake trivy-arm64)  trivy_0.75.2_Linux-ARM64.tar.gz
$(fake trivy-3f-b)  trivy_0.75.2_Linux-64bit.tar.gz
EOF
serve "$G/aquasecurity/trivy/releases/download/v0.75.2/trivy_0.75.2_checksums.txt" trivy-3f.txt
gh_release aquasecurity/trivy v0.75.2 "$OLD"
rc=0; "$bump" --root "$t" --unit trivy --to 0.75.2 --quiet --format json > "$work/r5b.json" 2> "$work/r5b.err" || rc=$?
check "a line with three fields is an error (exit 1)" [ "$rc:$(field "$work/r5b.json" trivy status)" = "1:error" ]
check "  and names the line" grep -q 'line 1 of .* is not in the expected checksum format' "$work/r5b.err"
# kubectl 1.38.1: the bare-hash file carries a name after the hash.
printf '%s  kubectl\n' "$(fake kubectl-amd64-2)" > "$fx/kubectl-2f"
printf '%s\n' "$(fake kubectl-arm64-2)" > "$fx/kubectl-arm64-2"
serve "https://dl.k8s.io/release/v1.38.1/bin/linux/amd64/kubectl.sha256" kubectl-2f
serve "https://dl.k8s.io/release/v1.38.1/bin/linux/arm64/kubectl.sha256" kubectl-arm64-2
gh_release kubernetes/kubernetes v1.38.1 "$OLD"
rc=0; "$bump" --root "$t" --unit kubectl --to 1.38.1 --quiet --format json > "$work/r5c.json" 2>/dev/null || rc=$?
check "a bare-hash file with a second field is an error (exit 1)" [ "$rc:$(field "$work/r5c.json" kubectl status)" = "1:error" ]
check "none of the three edited anything" [ -z "$(changed_files "$t" "$work/five.snap")" ]

echo "case 5b: which images carry a shared pin is read from images.json"
t=$(new_tree fiveb)
# An image added by the lifecycle: a third Node image, pinning npm like the others.
first_node=$(printf '%s\n' "$NODE_FILES" | head -1)
mkdir -p "$t/ci-node99"; cp "$t/$first_node" "$t/ci-node99/Dockerfile.ci"
jq '. + [{image: "ci-node99", version: "trixie-v1", mirror: "mirror-node:99-trixie-slim", upstream: "node:99-trixie-slim"}]' \
  "$t/.github/images.json" > "$t/i.json" && mv "$t/i.json" "$t/.github/images.json"
# And one retired: every image that pinned json leaves images.json.
# shellcheck disable=SC2086  # one path per word
jq --arg drop "$(printf '%s\n' $JSON_FILES | sed 's|/.*||')" 'map(select(.image as $i | $drop | split("\n") | index($i) | not))' \
  "$t/.github/images.json" > "$t/i.json" && mv "$t/i.json" "$t/.github/images.json"
rc=0; "$bump" --root "$t" --unit npm --to 12.2.0 --quiet --format json > "$work/r5d.json" 2>/dev/null || rc=$?
check "an added image's copy of the pin moves with the others" [ "$rc:$(pin "$t/ci-node99/Dockerfile.ci" NPM_VERSION)" = "0:12.2.0" ]
for f in $NODE_FILES; do expect_pin "$t" "$f" NPM_VERSION 12.2.0; done
rc=0; "$bump" --root "$t" --unit json --to 2.20.0 --quiet --format json > "$work/r5e.json" 2>/dev/null || rc=$?
check "a pin no image in images.json carries is an error, not a guess" [ "$rc:$(field "$work/r5e.json" json status)" = "1:error" ]
check "  and says so" bash -c "jq -r '.[0].error' '$work/r5e.json' | grep -q 'no image in .github/images.json pins'"
if [ -n "$JSON_FILES" ]; then
  for f in $JSON_FILES; do expect_pin "$t" "$f" JSON_VERSION 2.19.9; done
fi

# --- scripts/pin-bump-prs.sh ---------------------------------------------------
# Real git against a local bare repository as origin, so pushes, leases and
# the foreign-commit check run for real. The read-only gh queries are answered
# from PIN_BUMP_GH_STUB; every write goes to a fake gh on PATH that logs it
# (and fails the calls a case says should fail). No DRY_RUN: a dry run prints
# the writes instead of making them, so it could not show a write failing.
prs="$here/pin-bump-prs.sh"
BOT='41898282+github-actions[bot]@users.noreply.github.com'
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
# The fake: log the call, keep any --body-file, refuse what FAKE_GH_FAIL
# matches, answer `pr create` with a URL, and run FAKE_GH_HOOK once.
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
prev=""
for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$FAKE_GH_LOG.body"; prev="$a"; done
if [ -n "${FAKE_GH_HOOK:-}" ] && [ ! -e "$FAKE_GH_LOG.hooked" ]; then
  : > "$FAKE_GH_LOG.hooked"; eval "$FAKE_GH_HOOK"
fi
if [ -n "${FAKE_GH_FAIL:-}" ] && printf '%s\n' "$*" | grep -qE "$FAKE_GH_FAIL"; then
  echo "gh (fake): refused: $*" >&2; exit 1
fi
if [ "$1 $2" = "pr create" ]; then
  echo "https://github.com/o/r/pull/$((100 + $(grep -c '^pr create' "$FAKE_GH_LOG")))"
fi
exit 0
EOF
chmod +x "$work/bin/gh"

# CI result red: present, so it must not be dispatched again.
CHECKS_ALL='{"total_count":4,"check_runs":[{"name":"CI result","conclusion":"failure"},
  {"name":"Repository secret scan","conclusion":"success"},{"name":"CodeQL (workflows)","conclusion":"success"},
  {"name":"Dependency review","conclusion":"success"}]}'
CHECKS_NONE='{"total_count":0,"check_runs":[]}'

# scenario NAME -- fresh origin (main at the baseline pins), a clean clone to
# run in, a stub directory, and an empty gh log.
scenario() {
  local src
  d="$work/prs-$1"; rm -rf "$d"; mkdir -p "$d/stub"
  src=$(new_tree "prs-$1-src")
  git -C "$src" init -q -b main
  git -C "$src" add -A
  git -C "$src" -c user.name=base -c user.email=base@example.com commit -qm base
  git clone -q --bare "$src" "$d/origin.git"
  git clone -q "$d/origin.git" "$d/clone"
  origin="$d/origin.git"; stub="$d/stub"; log="$d/gh.log"; : > "$log"
  echo '[{"name":"needs-review"}]' > "$stub/labels.json"
}
# seed UNIT AUTHOR_EMAIL COMMITTER_EMAIL -- put pin-bump/UNIT on origin, one
# commit on main by those identities; prints its SHA.
seed() {
  local s="$d/seed-$1"
  rm -rf "$s"; git clone -q "$origin" "$s"
  echo "# seeded" >> "$s/ci-security/Dockerfile.ci"
  git -C "$s" add -A
  GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL="$2" GIT_COMMITTER_NAME=c GIT_COMMITTER_EMAIL="$3" \
    git -C "$s" commit -qm seed
  git -C "$s" push -q origin "HEAD:refs/heads/pin-bump/$1"
  git -C "$s" rev-parse HEAD
}
# pr UNIT NUMBER STATE TO [CLASS] -- the stubbed `gh pr list` answer for UNIT.
pr() {
  jq -n --arg u "$1" --argjson n "$2" --arg s "$3" --arg to "$4" --arg c "${5:-}" \
    '[{number:$n, state:$s, url:("https://github.com/o/r/pull/" + ($n|tostring)),
       body:("text\n<!-- pin-bump: unit=" + $u + " to=" + $to + (if $c == "" then "" else " class=" + $c end) + " -->"),
       headRefName:("pin-bump/" + $u), isCrossRepository:false, labels:[]}]' > "$stub/pr-$1.json"
}
# run_prs -- drift rows ("tool latest") on stdin; sets rc, out, res.
run_prs() {
  drift > "$d/drift.json"
  out="$d/out"; res="$d/results.jsonl"; rc=0
  (cd "$d/clone" && PATH="$work/bin:$PATH" DRIFT_FILE="$d/drift.json" GITHUB_REPOSITORY=o/r \
     PIN_BUMP_GH_STUB="$stub" PIN_BUMP_RESULTS="$res" FAKE_GH_LOG="$log" "$prs") > "$out" 2>&1 || rc=$?
}
rfield() { jq -r --arg u "$1" --arg f "$2" 'select(.unit == $u) | .[$f]' "$res"; }
expect_row() { # UNIT FIELD VALUE
  local got; got=$(rfield "$1" "$2")
  if [ "$got" = "$3" ]; then ok "$1 $2 = $3"; else bad "$1 $2: expected $3, got $got"; fi
}
logged()     { grep -qxF -- "$1" "$log"; }
not_logged() { ! grep -qE -- "$1" "$log"; }
head_of()    { git -C "$origin" rev-parse -q --verify "refs/heads/$1" || true; }
main_sha()   { git -C "$origin" rev-parse refs/heads/main; }

echo "case 6a: new PRs -- an auto unit and a review unit"
scenario a
run_prs <<'EOF'
trivy 0.75.0
syft 2.0.0
EOF
check "exit 0" [ "$rc" -eq 0 ]
expect_row trivy status ok
expect_row trivy class auto
expect_row trivy pr https://github.com/o/r/pull/101
check "pin-bump/trivy is one commit on main" [ "$(git -C "$origin" rev-parse pin-bump/trivy^)" = "$(main_sha)" ]
check "  authored and committed by the bot" \
  [ "$(git -C "$origin" log -1 --format='%ae %ce' pin-bump/trivy)" = "$BOT $BOT" ]
check "  with the new version" \
  bash -c "git -C '$origin' show pin-bump/trivy:ci-security/Dockerfile.ci | grep -qx 'ARG TRIVY_VERSION=0.75.0'"
check "PR created for pin-bump/trivy" grep -q -- '^pr create .*--head pin-bump/trivy ' "$log"
check "Build and Push dispatched on the branch" logged "workflow run build-and-push.yml --repo o/r --ref pin-bump/trivy"
check "Security dispatched on the branch" logged "workflow run security.yml --repo o/r --ref pin-bump/trivy"
check "the review unit is labelled" logged "pr edit 102 --repo o/r --add-label needs-review"
check "nothing is merged or given auto-merge here: merge-bot-prs.sh merges" not_logged '^pr merge'
check "the body says it merges itself, and how to stop it" grep -q "Add the \`hold\` label to stop it" "$log.body"
check "the review body says the label is information" grep -q "Labelled \`needs-review\` for information" "$log.body"
check "the body records version and class for the next run" grep -qxF '<!-- pin-bump: unit=syft to=2.0.0 class=review -->' "$log.body"
check "the body warns against Update branch" grep -q 'do not use \*Update branch\*' "$log.body"

echo "case 6b: an open PR at an older version is rebuilt, and the push is leased"
scenario b
old_sha=$(seed trivy "$BOT" "$BOT")
pr trivy 7 OPEN 0.74.5 auto
run_prs <<< 'trivy 0.75.0'
check "exit 0" [ "$rc" -eq 0 ]
expect_row trivy action "updated #7 (was 0.74.5), build-and-push.yml dispatched, security.yml dispatched"
check "the branch moved off the old commit" [ "$(head_of pin-bump/trivy)" != "$old_sha" ]
check "  onto one new commit on main" [ "$(git -C "$origin" rev-parse pin-bump/trivy^)" = "$(main_sha)" ]
check "title and body rewritten" grep -q -- '^pr edit 7 --repo o/r --title Bump trivy from 0.74.0 to 0.75.0 --body-file ' "$log"
# The lease: kubectl is processed first, and its first gh call moves
# pin-bump/trivy on origin after this run fetched it. trivy's push must fail.
scenario b2
seeded=$(seed trivy "$BOT" "$BOT")
pr trivy 7 OPEN 0.74.5 auto
# An explicit identity: a CI runner has no git user configured, and a commit
# that fails there would leave nothing to race against.
export FAKE_GH_HOOK="GIT_AUTHOR_NAME=m GIT_AUTHOR_EMAIL=m@example.com GIT_COMMITTER_NAME=m GIT_COMMITTER_EMAIL=m@example.com git -C '$d/seed-trivy' commit -q --allow-empty -m moved && git -C '$d/seed-trivy' push -q origin HEAD:refs/heads/pin-bump/trivy"
run_prs <<'EOF'
kubectl 1.38.0
trivy 0.75.0
EOF
unset FAKE_GH_HOOK
moved=$(git -C "$d/seed-trivy" rev-parse HEAD)
check "the hook moved the branch, so there was a race to lose" [ "$moved" != "$seeded" ]
check "exit 1" [ "$rc" -eq 1 ]
expect_row kubectl status ok
expect_row trivy status error
check "  the push was refused, so the moved branch survives" [ "$(head_of pin-bump/trivy)" = "$moved" ]
check "  and the PR was not edited" not_logged '^pr edit 7 '

echo "case 6c: same version, up to date, CI never reported -> dispatched again"
scenario c
sha=$(seed trivy "$BOT" "$BOT")
pr trivy 8 OPEN 0.75.0 auto
printf '%s' "$CHECKS_NONE" > "$stub/checks-trivy.json"
run_prs <<< 'trivy 0.75.0'
check "exit 0" [ "$rc" -eq 0 ]
expect_row trivy status unchanged
check "Build and Push re-dispatched" logged "workflow run build-and-push.yml --repo o/r --ref pin-bump/trivy"
check "Security re-dispatched" logged "workflow run security.yml --repo o/r --ref pin-bump/trivy"
check "the branch was not pushed" [ "$(head_of pin-bump/trivy)" = "$sha" ]
check "the PR was not edited or merged" not_logged '^pr (edit|merge) '
# Only the Security checks missing: only Security is dispatched.
scenario c2
seed trivy "$BOT" "$BOT" > /dev/null
pr trivy 8 OPEN 0.75.0 auto
echo '{"check_runs":[{"name":"CI result","conclusion":"success"}]}' > "$stub/checks-trivy.json"
run_prs <<< 'trivy 0.75.0'
check "only security.yml re-dispatched when only its checks are missing" \
  [ "$(grep '^workflow run' "$log")" = "workflow run security.yml --repo o/r --ref pin-bump/trivy" ]
# The check runs cannot be read: an error, not "all present".
scenario c3
seed trivy "$BOT" "$BOT" > /dev/null
pr trivy 8 OPEN 0.75.0 auto
echo '{"message":"Server Error"}' > "$stub/checks-trivy.json"; echo 1 > "$stub/checks-trivy.exit"
run_prs <<< 'trivy 0.75.0'
check "unreadable check runs: exit 1" [ "$rc" -eq 1 ]
expect_row trivy status error
check "  nothing dispatched on a guess" not_logged '^workflow run'
# CI result was cancelled: no result, so Build and Push is dispatched again.
scenario c4
seed trivy "$BOT" "$BOT" > /dev/null
pr trivy 8 OPEN 0.75.0 auto
jq '(.check_runs[] | select(.name == "CI result") | .conclusion) = "cancelled"' <<<"$CHECKS_ALL" > "$stub/checks-trivy.json"
run_prs <<< 'trivy 0.75.0'
check "a cancelled CI result: only build-and-push.yml re-dispatched" \
  [ "$(grep '^workflow run' "$log")" = "workflow run build-and-push.yml --repo o/r --ref pin-bump/trivy" ]

echo "case 6d: same version, CI present (red) -> left as it is"
scenario d
seed trivy "$BOT" "$BOT" > /dev/null
pr trivy 9 OPEN 0.75.0 auto
printf '%s' "$CHECKS_ALL" > "$stub/checks-trivy.json"
run_prs <<< 'trivy 0.75.0'
check "exit 0" [ "$rc" -eq 0 ]
expect_row trivy status unchanged
check "a red CI result is not dispatched again" not_logged '^workflow run'
check "  and nothing else is written either" not_logged '.'

echo "case 6e: commits not made by this workflow -> skipped, never pushed over"
scenario e
sha=$(seed trivy human@example.com "$BOT")
pr trivy 10 OPEN 0.75.0 auto
printf '%s' "$CHECKS_NONE" > "$stub/checks-trivy.json"
run_prs <<< 'trivy 0.75.0'
check "foreign author: exit 0" [ "$rc" -eq 0 ]
expect_row trivy status skipped
check "  no dispatch, no edit" not_logged '.'
check "  branch untouched" [ "$(head_of pin-bump/trivy)" = "$sha" ]
scenario e2
sha=$(seed trivy "$BOT" maintainer@example.com)
pr trivy 11 OPEN 0.74.5 auto
run_prs <<< 'trivy 0.75.0'
check "foreign committer (bot author, amended by a maintainer): exit 0" [ "$rc" -eq 0 ]
expect_row trivy status skipped
check "  the note names the committer" bash -c "jq -r 'select(.unit == \"trivy\") | .note' '$res' | grep -q maintainer@example.com"
check "  branch not force-pushed" [ "$(head_of pin-bump/trivy)" = "$sha" ]
check "  PR not edited" not_logged '.'

echo "case 6f: a PR closed unmerged at the same version is not reopened"
scenario f
pr trivy 12 CLOSED 0.75.0 auto
run_prs <<< 'trivy 0.75.0'
check "exit 0" [ "$rc" -eq 0 ]
expect_row trivy status skipped
check "no PR created, no push" [ -z "$(head_of pin-bump/trivy)" ]
check "  and no gh write at all" not_logged '.'

echo "case 6i: an auto PR refreshed to a review version -> labelled, nothing merged"
scenario i
seed syft "$BOT" "$BOT" > /dev/null
pr syft 12 OPEN 1.99.0 auto
run_prs <<< 'syft 2.0.0'
check "exit 0" [ "$rc" -eq 0 ]
expect_row syft status ok
check "labelled for review" logged "pr edit 12 --repo o/r --add-label needs-review"
check "  and no merge or auto-merge call of any kind" not_logged '^pr merge'
# The label cannot be set: information lost, not a failed unit.
scenario i2
seed syft "$BOT" "$BOT" > /dev/null
pr syft 12 OPEN 1.99.0 auto
FAKE_GH_FAIL='^pr edit 12 .*--add-label' run_prs <<< 'syft 2.0.0'
check "a refused label: exit 0" [ "$rc" -eq 0 ]
expect_row syft status ok
check "  the note says so" grep -q 'could not set the needs-review label' "$res"
check "  CI was still dispatched" logged "workflow run build-and-push.yml --repo o/r --ref pin-bump/syft"

echo "case 6h: a failed dispatch errors its unit, after every unit was processed"
scenario h
export FAKE_GH_FAIL='^workflow run build-and-push\.yml .*--ref pin-bump/kubectl$'
run_prs <<'EOF'
kubectl 1.38.0
trivy 0.75.0
EOF
unset FAKE_GH_FAIL
check "exit 1" [ "$rc" -eq 1 ]
expect_row kubectl status error
check "  the note says which dispatch failed" \
  bash -c "jq -r 'select(.unit == \"kubectl\") | .note' '$res' | grep -q 'gh workflow run build-and-push.yml failed (exit 1)'"
check "  its other workflow was still dispatched" logged "workflow run security.yml --repo o/r --ref pin-bump/kubectl"
expect_row trivy status ok
check "the unit after it was fully processed" logged "workflow run security.yml --repo o/r --ref pin-bump/trivy"

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
