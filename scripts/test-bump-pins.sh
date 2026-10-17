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

# A fake cosign, first on PATH for every case (pin-bump-prs.sh's included), so
# no test depends on a real one, or on Sigstore being reachable. It does what
# the real `cosign verify-blob --bundle` decides on: the bundle must be over
# this file's exact bytes and name exactly the identity and issuer asked for.
# Its "bundles" are written by sign_sigstore below. Every call is logged.
mkdir -p "$work/cosign-bin"
cat > "$work/cosign-bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_COSIGN_LOG"
[ "$1" = verify-blob ] || { echo "cosign (fake): only verify-blob" >&2; exit 2; }
shift
bundle="" id="" iss="" file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) bundle="$2"; shift 2 ;;
    --certificate-identity) id="$2"; shift 2 ;;
    --certificate-oidc-issuer) iss="$2"; shift 2 ;;
    -*) echo "cosign (fake): unexpected flag $1" >&2; exit 2 ;;
    *) file="$1"; shift ;;
  esac
done
if [ -z "$bundle" ] || [ -z "$id" ] || [ -z "$iss" ] || [ ! -f "$file" ]; then
  echo "Error: incomplete verify-blob call" >&2; exit 1
fi
jq -e --arg h "$(sha256sum "$file" | cut -d' ' -f1)" '.fake == "sigstore" and .sha256 == $h' "$bundle" >/dev/null 2>&1 \
  || { echo "Error: failed to verify signature" >&2; exit 1; }
jq -e --arg i "$id" --arg o "$iss" '.identity == $i and .issuer == $o' "$bundle" >/dev/null \
  || { echo "Error: no matching CertificateIdentity found" >&2; exit 1; }
echo "Verified OK" >&2
EOF
chmod +x "$work/cosign-bin/cosign"
export PATH="$work/cosign-bin:$PATH" FAKE_COSIGN_LOG="$work/cosign.log"
: > "$FAKE_COSIGN_LOG"
# sign_sigstore URL FILE IDENTITY [ISSUER] -- serve URL.sigstore.json, a fake
# bundle over fixture FILE's bytes as IDENTITY.
sign_sigstore() {
  jq -n --arg h "$(sha256sum "$fx/$2" | cut -d' ' -f1)" --arg i "$3" --arg o "${4:-https://token.actions.githubusercontent.com}" \
    '{fake: "sigstore", sha256: $h, identity: $i, issuer: $o}' > "$fx/$2.sigstore.json"
  serve "$1.sigstore.json" "$2.sigstore.json"
}
TRIVY_ID="$G/aquasecurity/trivy/.github/workflows/reusable-release.yaml@refs/tags/v"   # + the version
SYFT_ID="$G/anchore/syft/.github/workflows/release.yaml@refs/heads/main"

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
sign_sigstore "$G/aquasecurity/trivy/releases/download/v0.75.0/trivy_0.75.0_checksums.txt" trivy.txt "${TRIVY_ID}0.75.0"
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
sign_sigstore "$G/anchore/syft/releases/download/v2.0.0/syft_2.0.0_checksums.txt" syft.txt "$SYFT_ID"
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

# undici 6.29.1: a within-major registry bump of the copy swapped into npm's
# tree; 8.12.1, a newer major, is what the latest tag says.
cat > "$fx/undici.json" <<'EOF'
{"dist-tags":{"latest":"8.12.1","six":"6.29.1"},
 "versions":{"6.29.0":{"dist":{"integrity":"sha512-old"}},"6.29.1":{"dist":{"integrity":"sha512-dW5kaWNp"}},
             "8.12.1":{"dist":{"integrity":"sha512-bmV3"}}},
 "time":{"6.29.0":"2026-09-01T00:00:00.000Z","6.29.1":"2026-09-10T08:00:00.000Z","8.12.1":"2026-09-12T00:00:00.000Z"}}
EOF
serve "https://registry.npmjs.org/undici" undici.json

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
UNDICI_FILES=$(carriers NPM_UNDICI_VERSION)
if [ -z "$NODE_FILES" ] || [ -z "$PHP_FILES" ]; then
  echo "no image pins npm or Composer; these tests need one of each" >&2; exit 1
fi
# shellcheck disable=SC2206  # one path per word
files=(
  ci-tools/Dockerfile.ci ci-cloud/Dockerfile.ci ci-security/Dockerfile.ci ci-db/Dockerfile.ci
  $NODE_FILES $PHP_FILES $JSON_FILES .github/workflows/security.yml .github/workflows/build-image.yml
  scripts/lint.sh .github/images.json ci-cloud/az-overrides.txt .github/zizmor-requirements.txt
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
  for f in $UNDICI_FILES; do force "$t/$f" NPM_UNDICI_VERSION 6.29.0; done
  force "$t/ci-tools/Dockerfile.ci" AWSCLI_VERSION 2.38.1
  # A requirements pin: `name==version`, the hash lines after it untouched.
  sed -E 's/^urllib3==[^ ]+/urllib3==2.8.0/; s/^cryptography==[^ ]+/cryptography==50.0.2/' \
    "$t/ci-cloud/az-overrides.txt" > "$t/x" && cat "$t/x" > "$t/ci-cloud/az-overrides.txt" && rm "$t/x"
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

drift() { # rows as "tool latest [pinned]" -> a check-pins JSON report on stdout
  local rows="" tool latest pinned
  while read -r tool latest pinned; do
    rows="$rows$(jq -nc --arg t "$tool" --arg l "$latest" --arg p "${pinned:-x}" '{tool:$t, pinned:$p, latest:$l, file:"x", key:"x", state:"behind"}')"
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
check "  its checksums file's Sigstore bundle is listed as an integrity source" \
  bash -c "jq -e '.[] | select(.unit == \"trivy\") | .integrity_urls | index(\"$G/aquasecurity/trivy/releases/download/v0.75.0/trivy_0.75.0_checksums.txt.sigstore.json\")' '$work/r1.json' >/dev/null"
check "  cosign was asked for trivy's own release identity at that tag, and GitHub's issuer" \
  grep -qF -- "--certificate-identity ${TRIVY_ID}0.75.0 --certificate-oidc-issuer https://token.actions.githubusercontent.com" "$FAKE_COSIGN_LOG"
check "  and the reason says the signature verified" \
  bash -c "jq -r '.[] | select(.unit == \"trivy\") | .reason' '$work/r1.json' | grep -q 'Sigstore signature verified'"

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
sign_sigstore "$G/aquasecurity/trivy/releases/download/v0.75.1/trivy_0.75.1_checksums.txt" trivy-dup.txt "${TRIVY_ID}0.75.1"
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
sign_sigstore "$G/aquasecurity/trivy/releases/download/v0.75.2/trivy_0.75.2_checksums.txt" trivy-3f.txt "${TRIVY_ID}0.75.2"
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

echo "case 5c: check-pins -- a key no image carries is an error, unless the row is optional"
# Offline: both paths end before any vendor is asked. check-pins reads the
# tree it sits in, so it runs from a copy of itself inside the scratch tree.
t=$(new_tree fivec)
cp -p "$here/check-pins.sh" "$t/scripts/check-pins.sh"
sed 's/| NPM_VERSION  /| NPM_VERISON  /' "$here/check-pins.sh" > "$t/scripts/check-pins-typo.sh"; chmod +x "$t/scripts/check-pins-typo.sh"
check "  (the typo was planted)" grep -q 'NPM_VERISON' "$t/scripts/check-pins-typo.sh"
rc=0; "$t/scripts/check-pins-typo.sh" --only npm --format json > "$work/c5c.json" 2> "$work/c5c.err" || rc=$?
check "a typo'd key: exit 1, not a silent skip" [ "$rc" -eq 1 ]
check "  reported unresolved, so pin-bump turns it into an error row" \
  [ "$(jq -r '.tools[0].state + " " + .tools[0].key' "$work/c5c.json")" = "unresolved NPM_VERISON" ]
check "  and the log says why" grep -q 'no image in .github/images.json pins NPM_VERISON' "$work/c5c.err"
# The optional json row, once no image carries the replacement any more.
for f in $JSON_FILES; do sed '/^ARG JSON_VERSION=/d' "$t/$f" > "$t/x" && mv "$t/x" "$t/$f"; done
rc=0; "$t/scripts/check-pins.sh" --only json --format json > "$work/c5d.json" 2> "$work/c5d.err" || rc=$?
check "an optional key no image carries: exit 0, skipped" [ "$rc:$(jq '.tools | length' "$work/c5d.json")" = "0:0" ]
check "  and the log says so" grep -q 'json: no image in .github/images.json pins JSON_VERSION any more, and it is optional; skipped' "$work/c5d.err"
rc=0; "$t/scripts/check-pins.sh" --only nosuch > /dev/null 2>&1 || rc=$?
check "an unknown --only is still a usage error" [ "$rc" -eq 2 ]

echo "case 5d: npm's swapped-in undici moves in every Node image"
if [ -n "$UNDICI_FILES" ]; then
  t=$(new_tree fived)
  rc=0; "$bump" --root "$t" --unit npm-undici --to 6.29.1 --quiet --format json > "$work/r5f.json" 2>/dev/null || rc=$?
  check "exit 0" [ "$rc" -eq 0 ]
  expect_field "$work/r5f.json" npm-undici status bumped
  expect_field "$work/r5f.json" npm-undici class auto
  for f in $UNDICI_FILES; do expect_pin "$t" "$f" NPM_UNDICI_VERSION 6.29.1; done
  check "every Node image carries the pin, so the move is not vacuous" \
    [ "$(printf '%s\n' "$UNDICI_FILES" | wc -l)" -eq "$(printf '%s\n' "$NODE_FILES" | wc -l)" ]
  # check-pins resolves this pin within its major, but a hand-run --to that
  # crosses one is still only ever a review bump.
  rc=0; "$bump" --root "$t" --unit npm-undici --to 8.12.1 --quiet --format json > "$work/r5g.json" 2>/dev/null || rc=$?
  expect_field "$work/r5g.json" npm-undici class review
else
  # The replacement retired (npm bundles a fixed undici): nothing to move.
  ok "no image swaps undici into npm any more; skipped"
fi

echo "case 5e: the cooldown fails closed, and an asset uploaded late restarts it"
t=$(new_tree fivee); cp -a "$t" "$work/fivee.snap"
# trivy 0.76.0: its checksums are published, but the release record 404s.
printf '%s  trivy_0.76.0_Linux-64bit.tar.gz\n%s  trivy_0.76.0_Linux-ARM64.tar.gz\n' "$(fake t76a)" "$(fake t76b)" > "$fx/trivy-76.txt"
serve "$G/aquasecurity/trivy/releases/download/v0.76.0/trivy_0.76.0_checksums.txt" trivy-76.txt
serve "https://api.github.com/repos/aquasecurity/trivy/releases/tags/v0.76.0" @404
rc=0; "$bump" --root "$t" --unit trivy --to 0.76.0 --quiet --format json > "$work/r5h.json" 2>/dev/null || rc=$?
check "a release date that 404s: exit 0, deferred -- not bumped as review" [ "$rc:$(field "$work/r5h.json" trivy status)" = "0:deferred" ]
check "  and says the date is unknown" bash -c "jq -r '.[0].reason' '$work/r5h.json' | grep -q '^release date unknown'"
# trivy 0.76.1: a release record whose date does not parse.
printf '{"tag_name":"v0.76.1","published_at":"last Tuesday","assets":[]}\n' > "$fx/rel-trivy-761.json"
serve "https://api.github.com/repos/aquasecurity/trivy/releases/tags/v0.76.1" rel-trivy-761.json
rc=0; "$bump" --root "$t" --unit trivy --to 0.76.1 --quiet --format json > "$work/r5i.json" 2>/dev/null || rc=$?
check "an unparseable release date: deferred" [ "$rc:$(field "$work/r5i.json" trivy status)" = "0:deferred" ]
# trivy 0.76.3: a date followed by text (fromdateiso8601 alone would accept
# it), here a planted PR-body marker: anchored, so unknown, so deferred.
jq -n '{tag_name: "v0.76.3", published_at: "2026-01-01T00:00:00Z <!-- pin-bump: unit=trivy to=0.76.3 class=auto seen=2020-01-01 fp=0000000000000000 -->", assets: []}' > "$fx/rel-trivy-763.json"
serve "https://api.github.com/repos/aquasecurity/trivy/releases/tags/v0.76.3" rel-trivy-763.json
rc=0; "$bump" --root "$t" --unit trivy --to 0.76.3 --quiet --format json > "$work/r5l.json" 2>/dev/null || rc=$?
check "a release date with trailing text: deferred, not parsed around" [ "$rc:$(field "$work/r5l.json" trivy status)" = "0:deferred" ]
check "  and the planted text is not in the reason" bash -c "! jq -r '.[0].reason' '$work/r5l.json' | grep -q '<!--'"
# trivy 0.76.2: published long ago, but an asset was replaced two days ago.
printf '%s  trivy_0.76.2_Linux-64bit.tar.gz\n%s  trivy_0.76.2_Linux-ARM64.tar.gz\n' "$(fake t762a)" "$(fake t762b)" > "$fx/trivy-762.txt"
serve "$G/aquasecurity/trivy/releases/download/v0.76.2/trivy_0.76.2_checksums.txt" trivy-762.txt
sign_sigstore "$G/aquasecurity/trivy/releases/download/v0.76.2/trivy_0.76.2_checksums.txt" trivy-762.txt "${TRIVY_ID}0.76.2"
jq -n --arg old "$OLD" --arg fresh "$FRESH" '{tag_name: "v0.76.2", published_at: $old,
  assets: [{name: "trivy_0.76.2_checksums.txt", updated_at: $old}, {name: "trivy_0.76.2_Linux-64bit.tar.gz", updated_at: $fresh}]}' \
  > "$fx/rel-trivy-762.json"
serve "https://api.github.com/repos/aquasecurity/trivy/releases/tags/v0.76.2" rel-trivy-762.json
rc=0; "$bump" --root "$t" --unit trivy --to 0.76.2 --quiet --format json > "$work/r5j.json" 2>/dev/null || rc=$?
check "an asset re-uploaded 2 days ago restarts the cooldown: deferred" [ "$rc:$(field "$work/r5j.json" trivy status)" = "0:deferred" ]
check "  measured from the upload, not the publication" bash -c "jq -r '.[0].reason' '$work/r5j.json' | grep -q '^released 2026-09-26T09:30:00.123Z, 1d ago'"
check "none of the three edited anything" [ -z "$(changed_files "$t" "$work/fivee.snap")" ]
# The same release a week on: the asset's date is past the cooldown too.
rc=0; BUMP_PINS_NOW=$((NOW + 7 * 86400)) "$bump" --root "$t" --unit trivy --to 0.76.2 --quiet --format json > "$work/r5k.json" 2>/dev/null || rc=$?
check "  and a week later it is bumped" [ "$rc:$(field "$work/r5k.json" trivy status)" = "0:bumped" ]

echo "case 5f: requirements-file pins take every linux wheel's hash from PyPI"
t=$(new_tree fivef); cp -a "$t" "$work/fivef.snap"
pypi_file() { # FILENAME SHA256-LABEL UPLOADED [YANKED]
  jq -nc --arg f "$1" --arg h "$(fake "$2")" --arg u "$3" --argjson y "${4:-false}" \
    '{filename: $f, packagetype: (if ($f | endswith(".whl")) then "bdist_wheel" else "sdist" end),
      digests: {sha256: $h}, upload_time_iso_8601: $u, yanked: $y}'
}
{ pypi_file urllib3-2.8.1-py3-none-any.whl u281-whl "$OLD"; pypi_file urllib3-2.8.1.tar.gz u281-sdist "$OLD"; } \
  | jq -s '{info: {version: "2.8.1"}, urls: .}' > "$fx/pypi-urllib3.json"
serve "https://pypi.org/pypi/urllib3/2.8.1/json" pypi-urllib3.json
rc=0; "$bump" --root "$t" --unit az-urllib3 --to 2.8.1 --quiet --format json > "$work/r5l.json" 2>/dev/null || rc=$?
check "a pure-Python wheel: exit 0, auto" [ "$rc:$(field "$work/r5l.json" az-urllib3 status):$(field "$work/r5l.json" az-urllib3 class)" = "0:bumped:auto" ]
check "  version and the one wheel's hash written together, the sdist left out" \
  bash -c "awk '/^urllib3==/ { p = 1 } p { print } p && !/\\\\\$/ { exit }' '$t/ci-cloud/az-overrides.txt' | tr -d ' \\\\' | paste -sd' ' - | grep -qx 'urllib3==2.8.1 --hash=sha256:$(fake u281-whl)'"
check "  the other requirements untouched" \
  [ "$(grep -v -A1 '^urllib3==' "$t/ci-cloud/az-overrides.txt" | grep -c 'hash=')" -eq "$(grep -v -A1 '^urllib3==' "$work/fivef.snap/ci-cloud/az-overrides.txt" | grep -c 'hash=')" ]
check "  and the result still passes --check" "$bump" --root "$t" --check --quiet
# cryptography 50.0.3: x86_64 wheels only -- an arm64 build would fail.
{ pypi_file cryptography-50.0.3-cp311-abi3-manylinux_2_34_x86_64.whl c503-x "$OLD"
  pypi_file cryptography-50.0.3-cp311-abi3-musllinux_1_2_aarch64.whl c503-m "$OLD"; } \
  | jq -s '{urls: .}' > "$fx/pypi-crypto.json"
serve "https://pypi.org/pypi/cryptography/50.0.3/json" pypi-crypto.json
rc=0; "$bump" --root "$t" --unit az-cryptography --to 50.0.3 --quiet --format json > "$work/r5m.json" 2>/dev/null || rc=$?
check "no glibc aarch64 wheel: exit 1, error" [ "$rc:$(field "$work/r5m.json" az-cryptography status)" = "1:error" ]
# cryptography 50.0.4: both, but one is yanked.
{ pypi_file cryptography-50.0.4-cp311-abi3-manylinux_2_34_x86_64.whl c504-x "$OLD"
  pypi_file cryptography-50.0.4-cp311-abi3-manylinux_2_34_aarch64.whl c504-a "$OLD" true; } \
  | jq -s '{urls: .}' > "$fx/pypi-crypto4.json"
serve "https://pypi.org/pypi/cryptography/50.0.4/json" pypi-crypto4.json
rc=0; "$bump" --root "$t" --unit az-cryptography --to 50.0.4 --quiet --format json > "$work/r5n.json" 2>/dev/null || rc=$?
check "a yanked wheel: exit 1, error" [ "$rc:$(field "$work/r5n.json" az-cryptography status)" = "1:error" ]
check "  cryptography untouched" [ "$(grep -A12 '^cryptography==' "$t/ci-cloud/az-overrides.txt")" = "$(grep -A12 '^cryptography==' "$work/fivef.snap/ci-cloud/az-overrides.txt")" ]

echo "case 5g: the AWS CLI is hashed only after AWS's signature verifies"
if command -v gpg >/dev/null && command -v gpgv >/dev/null; then
  t=$(new_tree fiveg); cp -a "$t" "$work/fiveg.snap"
  export GNUPGHOME="$work/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Test AWS CLI <t@example.com>' rsa2048 sign never 2>/dev/null
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Someone else <x@example.com>' rsa2048 sign never 2>/dev/null
  fpr=$(gpg --batch --with-colons --list-keys t@example.com 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  mkdir -p "$work/keys"; gpg --batch --armor --export t@example.com > "$work/keys/aws-cli.asc" 2>/dev/null
  for a in x86_64 aarch64; do
    for v in 2.38.2 2.38.3; do
      printf 'zip %s %s\n' "$a" "$v" > "$fx/aws-$a-$v.zip"
      serve "https://awscli.amazonaws.com/awscli-exe-linux-$a-$v.zip" "aws-$a-$v.zip"
    done
    gpg --batch --quiet --yes --local-user t@example.com --detach-sign -o "$fx/aws-$a-2.38.2.zip.sig" "$fx/aws-$a-2.38.2.zip" 2>/dev/null
    serve "https://awscli.amazonaws.com/awscli-exe-linux-$a-2.38.2.zip.sig" "aws-$a-2.38.2.zip.sig"
  done
  # 2.38.3: the aarch64 signature is by another key.
  gpg --batch --quiet --yes --local-user t@example.com --detach-sign -o "$fx/aws-x86_64-2.38.3.zip.sig" "$fx/aws-x86_64-2.38.3.zip" 2>/dev/null
  gpg --batch --quiet --yes --local-user x@example.com --detach-sign -o "$fx/aws-aarch64-2.38.3.zip.sig" "$fx/aws-aarch64-2.38.3.zip" 2>/dev/null
  serve "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.38.3.zip.sig" aws-x86_64-2.38.3.zip.sig
  serve "https://awscli.amazonaws.com/awscli-exe-linux-aarch64-2.38.3.zip.sig" aws-aarch64-2.38.3.zip.sig
  rc=0; BUMP_PINS_KEYS="$work/keys" BUMP_PINS_KEY_FPR="$fpr" \
    "$bump" --root "$t" --unit awscli --to 2.38.3 --quiet --format json > "$work/r5o.json" 2>/dev/null || rc=$?
  check "a signature by another key: exit 1, error" [ "$rc:$(field "$work/r5o.json" awscli status)" = "1:error" ]
  check "  nothing edited" [ -z "$(changed_files "$t" "$work/fiveg.snap")" ]
  rc=0; BUMP_PINS_KEYS="$work/keys" BUMP_PINS_KEY_FPR=FB5DB77FD5C118B80511ADA8A6310ACC4672475C \
    "$bump" --root "$t" --unit awscli --to 2.38.2 --quiet --format json > "$work/r5p.json" 2>/dev/null || rc=$?
  check "a key file that is not the pinned fingerprint: exit 1, error" [ "$rc:$(field "$work/r5p.json" awscli status)" = "1:error" ]
  rc=0; BUMP_PINS_KEYS="$work/keys" BUMP_PINS_KEY_FPR="$fpr" \
    "$bump" --root "$t" --unit awscli --to 2.38.2 --quiet --format json > "$work/r5q.json" 2>/dev/null || rc=$?
  check "a good signature: exit 0, bumped, review" [ "$rc:$(field "$work/r5q.json" awscli status):$(field "$work/r5q.json" awscli class)" = "0:bumped:review" ]
  check "  first-seen cooldown" [ "$(field "$work/r5q.json" awscli cooldown)" = first-seen ]
  expect_pin "$t" ci-tools/Dockerfile.ci AWSCLI_VERSION 2.38.2
  expect_pin "$t" ci-tools/Dockerfile.ci AWSCLI_SHA256_AMD64 "$(sha256sum "$fx/aws-x86_64-2.38.2.zip" | cut -d' ' -f1)"
  expect_pin "$t" ci-tools/Dockerfile.ci AWSCLI_SHA256_ARM64 "$(sha256sum "$fx/aws-aarch64-2.38.2.zip" | cut -d' ' -f1)"
  check "  the signatures are listed as the integrity source" \
    [ "$(jq -r '.[0].integrity_urls | map(select(endswith(".sig"))) | length' "$work/r5q.json")" -eq 2 ]

  echo "case 5g2: terraform's SHA256SUMS is read only after HashiCorp's signature verifies"
  t=$(new_tree fiveg2); force "$t/ci-tools/Dockerfile.ci" TERRAFORM_VERSION 1.16.5; cp -a "$t" "$work/fiveg2.snap"
  gpg --batch --armor --export t@example.com > "$work/keys/hashicorp.asc" 2>/dev/null
  hc=https://releases.hashicorp.com/terraform
  for v in 1.16.7 1.16.8 1.16.9; do
    printf '%s  terraform_%s_linux_amd64.zip\n%s  terraform_%s_linux_arm64.zip\n' \
      "$(fake "tf-$v-amd64")" "$v" "$(fake "tf-$v-arm64")" "$v" > "$fx/tf-$v.txt"
    serve "$hc/$v/terraform_${v}_SHA256SUMS" "tf-$v.txt"
    printf '{"timestamp_created":"%s"}\n' "$OLD" > "$fx/tf-$v.json"
    serve "https://api.releases.hashicorp.com/v1/releases/terraform/$v" "tf-$v.json"
  done
  # 1.16.7 signed by the pinned key; 1.16.8 by another; 1.16.9 not at all.
  gpg --batch --quiet --yes --local-user t@example.com --detach-sign -o "$fx/tf-1.16.7.sig" "$fx/tf-1.16.7.txt" 2>/dev/null
  gpg --batch --quiet --yes --local-user x@example.com --detach-sign -o "$fx/tf-1.16.8.sig" "$fx/tf-1.16.8.txt" 2>/dev/null
  serve "$hc/1.16.7/terraform_1.16.7_SHA256SUMS.sig" tf-1.16.7.sig
  serve "$hc/1.16.8/terraform_1.16.8_SHA256SUMS.sig" tf-1.16.8.sig
  serve "$hc/1.16.9/terraform_1.16.9_SHA256SUMS.sig" @404
  rc=0; BUMP_PINS_KEYS="$work/keys" BUMP_PINS_KEY_FPR="$fpr" \
    "$bump" --root "$t" --unit terraform --to 1.16.8 --quiet --format json > "$work/r5r.json" 2>/dev/null || rc=$?
  check "SHA256SUMS signed by another key: exit 1, error" [ "$rc:$(field "$work/r5r.json" terraform status)" = "1:error" ]
  rc=0; BUMP_PINS_KEYS="$work/keys" BUMP_PINS_KEY_FPR="$fpr" \
    "$bump" --root "$t" --unit terraform --to 1.16.9 --quiet --format json > "$work/r5s.json" 2>/dev/null || rc=$?
  check "SHA256SUMS with no signature: exit 1, error" [ "$rc:$(field "$work/r5s.json" terraform status)" = "1:error" ]
  check "  neither edited anything" [ -z "$(changed_files "$t" "$work/fiveg2.snap")" ]
  rc=0; BUMP_PINS_KEYS="$work/keys" BUMP_PINS_KEY_FPR="$fpr" \
    "$bump" --root "$t" --unit terraform --to 1.16.7 --quiet --format json > "$work/r5t.json" 2>/dev/null || rc=$?
  check "a good signature: exit 0, bumped, auto" [ "$rc:$(field "$work/r5t.json" terraform status):$(field "$work/r5t.json" terraform class)" = "0:bumped:auto" ]
  expect_pin "$t" ci-tools/Dockerfile.ci TERRAFORM_SHA256_AMD64 "$(fake tf-1.16.7-amd64)"
  expect_pin "$t" ci-tools/Dockerfile.ci TERRAFORM_SHA256_ARM64 "$(fake tf-1.16.7-arm64)"
  check "  the signature is listed once, beside the SHA256SUMS" \
    [ "$(jq -r '.[0].integrity_urls | join(" ")' "$work/r5t.json")" = "$hc/1.16.7/terraform_1.16.7_SHA256SUMS $hc/1.16.7/terraform_1.16.7_SHA256SUMS.sig" ]
  unset GNUPGHOME
else
  ok "gpg/gpgv not installed; signature cases skipped"
fi

echo "case 5i: a checksums file is read only after its Sigstore bundle verifies as the vendor"
t=$(new_tree fivei); cp -a "$t" "$work/fivei.snap"
tr_url() { printf '%s' "$G/aquasecurity/trivy/releases/download/v$1/trivy_$1_checksums.txt"; }
for v in 0.77.0 0.77.1 0.77.2 0.77.3 0.77.4; do
  printf '%s  trivy_%s_Linux-64bit.tar.gz\n%s  trivy_%s_Linux-ARM64.tar.gz\n' "$(fake "t-$v-a")" "$v" "$(fake "t-$v-b")" "$v" > "$fx/trivy-$v.txt"
  serve "$(tr_url "$v")" "trivy-$v.txt"
  gh_release aquasecurity/trivy "v$v" "$OLD"
done
# 0.77.0: no bundle published.
serve "$(tr_url 0.77.0).sigstore.json" @404
# 0.77.1: a bundle over different bytes -- the checksums file was swapped after signing.
printf 'something else\n' > "$fx/trivy-other.txt"
sign_sigstore "$(tr_url 0.77.1)" trivy-other.txt "${TRIVY_ID}0.77.1"
cp "$fx/trivy-other.txt.sigstore.json" "$fx/trivy-0.77.1.txt.sigstore.json"
# 0.77.2: a genuine-looking bundle, but from a fork's copy of the release workflow.
sign_sigstore "$(tr_url 0.77.2)" trivy-0.77.2.txt "$G/attacker/trivy/.github/workflows/reusable-release.yaml@refs/tags/v0.77.2"
# 0.77.3: trivy's own workflow, but the run for another tag.
sign_sigstore "$(tr_url 0.77.3)" trivy-0.77.3.txt "${TRIVY_ID}0.77.2"
# 0.77.4: trivy's workflow at its own tag, but a token from another issuer.
sign_sigstore "$(tr_url 0.77.4)" trivy-0.77.4.txt "${TRIVY_ID}0.77.4" https://accounts.google.com
for c in "0.77.0:no bundle" "0.77.1:a bundle over other bytes" "0.77.2:another repository's identity" \
         "0.77.3:the release run for another tag" "0.77.4:another OIDC issuer"; do
  rc=0; "$bump" --root "$t" --unit trivy --to "${c%%:*}" --quiet --format json > "$work/r5i.json" 2> "$work/r5i.err" || rc=$?
  check "${c#*:}: exit 1, error" [ "$rc:$(field "$work/r5i.json" trivy status)" = "1:error" ]
  check "  blamed on the signature" bash -c "jq -r '.[0].error' '$work/r5i.json' | grep -q 'vendor signature on .* does not verify'"
done
check "  none of them edited anything" [ -z "$(changed_files "$t" "$work/fivei.snap")" ]
# And the good one, so the failures above are the signature and nothing else.
sign_sigstore "$(tr_url 0.77.3)" trivy-0.77.3.txt "${TRIVY_ID}0.77.3"
rc=0; "$bump" --root "$t" --unit trivy --to 0.77.3 --quiet --format json > "$work/r5i.json" 2>/dev/null || rc=$?
check "the right identity at the right tag: exit 0, bumped, auto" [ "$rc:$(field "$work/r5i.json" trivy status):$(field "$work/r5i.json" trivy class)" = "0:bumped:auto" ]
expect_pin "$t" ci-security/Dockerfile.ci TRIVY_SHA256_AMD64 "$(fake t-0.77.3-a)"
# The table carries the same check for every signed unit: syft's bundle is
# checked against anchore's identity, not trivy's.
printf '%s  syft_2.0.1_linux_amd64.tar.gz\n%s  syft_2.0.1_linux_arm64.tar.gz\n' "$(fake s201a)" "$(fake s201b)" > "$fx/syft-201.txt"
serve "$G/anchore/syft/releases/download/v2.0.1/syft_2.0.1_checksums.txt" syft-201.txt
sign_sigstore "$G/anchore/syft/releases/download/v2.0.1/syft_2.0.1_checksums.txt" syft-201.txt "${TRIVY_ID}2.0.1"
gh_release anchore/syft v2.0.1 "$OLD"
rc=0; "$bump" --root "$t" --unit syft --to 2.0.1 --quiet --format json > "$work/r5u.json" 2>/dev/null || rc=$?
check "syft signed as trivy: exit 1, error" [ "$rc:$(field "$work/r5u.json" syft status)" = "1:error" ]

echo "case 5j: --check -- a signed unit must have a signature row for every file it reads"
t=$(new_tree fivej); mkdir -p "$t/scripts/keys"; cp -p "$here"/keys/*.asc "$t/scripts/keys/"
cp -p "$bump" "$t/scripts/bp.sh"
check "  (the unmodified tables pass in this tree)" "$t/scripts/bp.sh" --root "$t" --check --quiet
grep -v '^awscli .*aarch64-{v}\.zip\.sig' "$bump" > "$t/scripts/bp.sh"
check "  (one awscli row was removed)" [ "$(grep -c '^awscli .*\.sig ' "$t/scripts/bp.sh")" -eq 1 ]
rc=0; "$t/scripts/bp.sh" --root "$t" --check > /dev/null 2> "$work/c5j.err" || rc=$?
check "an unsigned file beside a signed one fails --check" [ "$rc" -eq 1 ]
check "  and names it" grep -q 'awscli is signed, but https://awscli.amazonaws.com/awscli-exe-linux-aarch64-{v}.zip has no SIGS row' "$work/c5j.err"
sed 's|reusable-release.yaml@refs/tags/v{v} |reusable-release.yaml@.* |' "$bump" > "$t/scripts/bp.sh"
rc=0; "$t/scripts/bp.sh" --root "$t" --check > /dev/null 2> "$work/c5j.err" || rc=$?
check "an identity that is a pattern, not exact, fails --check" [ "$rc" -eq 1 ]

echo "case 5h: --check over the real tree"
check "every pin, checksum, tofu and signature row names exactly one line" "$bump" --check --quiet
check "the AWS key file is exactly the pinned key" \
  bash -c "GNUPGHOME=\$(mktemp -d) gpg --batch --show-keys --with-colons '$here/keys/aws-cli.asc' 2>/dev/null | awk -F: '\$1 == \"fpr\" { print \$10 }' | grep -qx FB5DB77FD5C118B80511ADA8A6310ACC4672475C"
check "the HashiCorp key file's primary key is exactly the pinned key" \
  bash -c "GNUPGHOME=\$(mktemp -d) gpg --batch --show-keys --with-colons '$here/keys/hashicorp.asc' 2>/dev/null | awk -F: '\$1 == \"pub\" { p = 1; next } p && \$1 == \"fpr\" { print \$10; p = 0 }' | grep -qx C874011F0AB405110D02105534365D9472D7468F"

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
# pr UNIT NUMBER STATE TO [CLASS [SEEN [FP]]] -- the stubbed `gh pr list`
# answer for UNIT. With a CLASS, the marker also carries the first-seen date
# and values digest (default 2026-09-20 and a fixed digest); SEEN "-" leaves
# both out, as a PR opened before the first-seen clock existed has them.
pr() {
  local extra=""
  if [ -n "${5:-}" ] && [ "${6:-}" != - ]; then extra=" seen=${6:-2026-09-20} fp=${7:-0123456789abcdef}"; fi
  jq -n --arg u "$1" --argjson n "$2" --arg s "$3" --arg to "$4" --arg c "${5:-}" --arg x "$extra" \
    '[{number:$n, state:$s, url:("https://github.com/o/r/pull/" + ($n|tostring)),
       body:("text\n<!-- pin-bump: unit=" + $u + " to=" + $to + (if $c == "" then "" else " class=" + $c end) + $x + " -->"),
       headRefName:("pin-bump/" + $u), isCrossRepository:false, labels:[]}]' > "$stub/pr-$1.json"
}
# run_prs -- drift rows ("tool latest") on stdin; sets rc, out, res.
run_prs() {
  drift > "$d/drift.json"
  out="$d/out"; res="$d/results.jsonl"; rc=0
  (cd "$d/clone" && PATH="$work/bin:$PATH" DRIFT_FILE="$d/drift.json" GITHUB_REPOSITORY=o/r \
     PIN_BUMP_GH_STUB="$stub" PIN_BUMP_RESULTS="$res" FAKE_GH_LOG="$log" PIN_BUMP_TODAY=2026-09-28 "$prs") > "$out" 2>&1 || rc=$?
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
check "the body records version, class and first-seen date for the next run" \
  grep -qxE '<!-- pin-bump: unit=syft to=2\.0\.0 class=review seen=2026-09-28 fp=[0-9a-f]{16} -->' "$log.body"
check "  and says when the cooldown lets it merge" grep -qF '| First seen | 2026-09-28: merges no earlier than **2026-10-05** |' "$log.body"
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

echo "case 6j: a review bump with no vendor date records its first-seen date"
printf 'docker 29.9.1 amd64\n' > "$fx/docker-2991-amd64"; printf 'docker 29.9.1 arm64\n' > "$fx/docker-2991-arm64"
serve "https://download.docker.com/linux/static/stable/x86_64/docker-29.9.1.tgz" docker-2991-amd64
serve "https://download.docker.com/linux/static/stable/aarch64/docker-29.9.1.tgz" docker-2991-arm64
# advance_main -- one commit on origin's main, so a pin-bump branch is behind it.
advance_main() {
  local s="$d/advance"
  rm -rf "$s"; git clone -q "$origin" "$s"
  echo moved > "$s/MOVED"; git -C "$s" add -A
  git -C "$s" -c user.name=b -c user.email=b@example.com commit -qm moved
  git -C "$s" push -q origin HEAD:refs/heads/main
}
marker_of() { grep -oE '<!-- pin-bump: [^>]* -->' "$log.body" | tail -1; }
scenario j
run_prs <<< 'docker 29.9.0'
check "exit 0" [ "$rc" -eq 0 ]
expect_row docker class review
check "the marker records today as first seen" bash -c "grep -oE '<!-- pin-bump: [^>]* -->' '$log.body' | grep -qE '^<!-- pin-bump: unit=docker to=29\.9\.0 class=review seen=2026-09-28 fp=[0-9a-f]{16} -->$'"
check "  the body says it merges itself, no earlier than seven days on" grep -qF 'merges no earlier than **2026-10-05**' "$log.body"
check "  and so does the summary" bash -c "jq -r 'select(.unit == \"docker\") | .action' '$res' | grep -qF 'first seen 2026-09-28 (merges from 2026-10-05)'"
fp_docker=$(marker_of | sed -E 's/.* fp=([0-9a-f]+) -->/\1/')

echo "case 6k: the first-seen date survives a rebuild of the same version, and only that"
scenario k
seed docker "$BOT" "$BOT" > /dev/null
advance_main
pr docker 20 OPEN 29.9.0 review 2026-09-25 "$fp_docker"
run_prs <<< 'docker 29.9.0'
check "exit 0" [ "$rc" -eq 0 ]
expect_row docker status ok
check "  rebuilt, because the branch was behind main" bash -c "jq -r 'select(.unit == \"docker\") | .note' '$res' | grep -q 'rebuilt because the branch was behind main'"
check "  onto the new main" [ "$(git -C "$origin" rev-parse pin-bump/docker^)" = "$(main_sha)" ]
check "  the first-seen date is kept: the daily rebuild does not restart the clock" \
  bash -c "grep -qF 'class=review seen=2026-09-25 fp=$fp_docker -->' '$log.body'"
# Same version, but the artifact behind it changed: a new clock.
scenario k2
seed docker "$BOT" "$BOT" > /dev/null
advance_main
pr docker 20 OPEN 29.9.0 review 2026-09-25 ffffffffffffffff
run_prs <<< 'docker 29.9.0'
expect_row docker status ok
check "a sum that changed under the same version restarts the clock" \
  bash -c "grep -qF 'class=review seen=2026-09-28 fp=$fp_docker -->' '$log.body'"
check "  and says so" bash -c "jq -r 'select(.unit == \"docker\") | .note' '$res' | grep -q 'first-seen clock restarted'"
# The same, with the branch up to date with main (the heal path): a review
# PR is re-verified, not healed on trust, so a replaced artifact still
# restarts the clock...
scenario k4
seed docker "$BOT" "$BOT" > /dev/null
pr docker 20 OPEN 29.9.0 review 2026-09-25 ffffffffffffffff
run_prs <<< 'docker 29.9.0'
expect_row docker status ok
check "an up-to-date review PR whose sums changed is rebuilt with a new clock" \
  bash -c "grep -qF 'class=review seen=2026-09-28 fp=$fp_docker -->' '$log.body'"
# ...and one whose values are unchanged is healed, branch untouched.
scenario k5
sha=$(seed docker "$BOT" "$BOT")
pr docker 20 OPEN 29.9.0 review 2026-09-25 "$fp_docker"
printf '%s' "$CHECKS_ALL" > "$stub/checks-docker.json"
run_prs <<< 'docker 29.9.0'
check "an up-to-date review PR with the same values is healed, not rebuilt" [ "$(head_of pin-bump/docker)" = "$sha" ]
expect_row docker status unchanged
# A PR from before the clock existed: rebuilt, so its marker gets a date.
scenario k3
seed docker "$BOT" "$BOT" > /dev/null
pr docker 20 OPEN 29.9.0 review -
run_prs <<< 'docker 29.9.0'
expect_row docker status ok
check "a marker with no first-seen date is rebuilt to record one" \
  bash -c "grep -qF 'class=review seen=2026-09-28 fp=$fp_docker -->' '$log.body'"

echo "case 6l: inside its cooldown a review PR keeps its version; after it, it moves on"
scenario l
sha=$(seed docker "$BOT" "$BOT")
pr docker 21 OPEN 29.9.0 review 2026-09-25 "$fp_docker"
printf '%s' "$CHECKS_ALL" > "$stub/checks-docker.json"
run_prs <<< 'docker 29.9.1 29.8.1'
check "exit 0" [ "$rc" -eq 0 ]
expect_row docker status unchanged
expect_row docker new 29.9.0
check "  the note says why" bash -c "jq -r 'select(.unit == \"docker\") | .note' '$res' | grep -q 'kept at 29.9.0, first seen 2026-09-25, until its cooldown ends on 2026-10-02'"
check "  the branch is not rebuilt, so the clock keeps running" [ "$(head_of pin-bump/docker)" = "$sha" ]
# Past its cooldown but inside the grace window: still held, so a day the
# merge bot missed does not restart the clock on a newer version.
scenario l3
sha=$(seed docker "$BOT" "$BOT")
pr docker 21 OPEN 29.9.0 review 2026-09-18 "$fp_docker"
printf '%s' "$CHECKS_ALL" > "$stub/checks-docker.json"
run_prs <<< 'docker 29.9.1 29.8.1'
expect_row docker status unchanged
expect_row docker new 29.9.0
check "  past its cooldown, inside the grace window: still held" \
  bash -c "jq -r 'select(.unit == \"docker\") | .note' '$res' | grep -q 'mergeable since 2026-09-25, until 2026-10-02 so the merge bot can take it'"
check "  the branch is not rebuilt" [ "$(head_of pin-bump/docker)" = "$sha" ]
scenario l2
seed docker "$BOT" "$BOT" > /dev/null
pr docker 21 OPEN 29.9.0 review 2026-09-01 "$fp_docker"
run_prs <<< 'docker 29.9.1 29.8.1'
expect_row docker status ok
expect_row docker new 29.9.1
check "after its cooldown and grace window, the newer version is proposed, with a fresh clock" \
  bash -c "grep -qE 'unit=docker to=29\.9\.1 class=review seen=2026-09-28 fp=' '$log.body'"
check "  hashed from its own download" \
  bash -c "git -C '$origin' show pin-bump/docker:ci-tools/Dockerfile.ci | grep -qx 'ARG DOCKER_SHA256_ARM64=$(sha256sum "$fx/docker-2991-arm64" | cut -d' ' -f1)'"

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
