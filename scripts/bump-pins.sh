#!/usr/bin/env bash
# Rewrite hand-pinned tool versions, and their checksums, to a newer vendor
# release -- in the working tree only. scripts/check-pins.sh finds the drift;
# this moves the pins; the pin-bump workflow turns each move into a pull request
# that the full CI then has to pass (docs/adr/0007-automatic-updates.md).
#
#   ./scripts/bump-pins.sh --drift report.json      # every "behind" row in a check-pins report
#   ./scripts/bump-pins.sh --unit kubectl           # one unit, to the vendor's latest
#   ./scripts/bump-pins.sh --unit kubectl --to 1.38.1
#   ./scripts/bump-pins.sh --plan --drift report.json   # list the units, touch nothing
#
# A "unit" is what moves together. Usually one tool, but a pin that lives in
# more than one place is one unit, so its copies can never be moved apart:
# kubectl (ci-tools + ci-cloud), Composer (every PHP image), gitleaks
# (ci-security + security.yml), npm and Playwright (every Node image), and the
# brace-expansion and undici copies swapped into npm's tree (every Node image;
# check-pins.sh resolves those within their current major).
#
# A pin written `*/Dockerfile.ci:KEY` is every image in .github/images.json
# whose Dockerfile.ci has an `ARG KEY=` line, so an image the lifecycle
# workflow adds or retires (scripts/image-lifecycle.sh) carries its pins in or
# out with it, and no image name is spelled here for those.
#
# Where the checksums come from is the point of this script. Wherever the
# vendor publishes one, every checksum it writes is read from the vendor's own
# published checksums file or registry record for that exact version (PyPI's
# JSON API, for the Python wheels) -- never computed from a download. A hash of
# something we fetched attests only to what we happened to fetch; if that fetch
# were tampered with we would pin the tampered digest and every later check
# would pass. The build's `sha256sum --check` is then the cross-verification:
# if the vendor's file and the vendor's artifact ever disagree, CI goes red.
#
# The exception is the three vendors that publish no checksum at all: the AWS
# CLI, the Docker static client and gcloud (integrity "tofu"). For those this
# script downloads each artifact and records the sha256 of what it got --
# trust on first use. That cannot prove the first download was genuine, but it
# pins it: every later build, the daily rebuilds included, fails on a
# substituted file instead of installing it, which before these pins nothing
# noticed. Where the vendor signs the artifact (AWS's detached .sig), the
# signature is verified against a key pinned by fingerprint before the hash is
# recorded, so for the AWS CLI the first use is checked too. A tofu bump is
# always `review`, and is not merged until it has waited the cooldown on the
# pin-bump PR's own first-seen clock (scripts/pin-bump-prs.sh records it,
# scripts/merge-bot-prs.sh enforces it): with no vendor release date to
# measure from, the clock starts on the day this repository first saw it.
#
# Each bump is classified:
#   auto    the vendor publishes a checksum (or the registry an integrity
#           digest), the version change is not a semver major, and the release
#           is at least the cooldown old. Safe to merge once CI is green.
#   review  anything else that can still be bumped: no vendor checksum (AWS
#           CLI, Docker client, gcloud) or a major version. It merges itself
#           once CI is green, but only after its PR has carried that exact
#           version for the cooldown (the first-seen clock above).
# and a release younger than the cooldown (BUMP_COOLDOWN_DAYS, default 7, the
# same seven days Dependabot waits) is not bumped at all this run: "deferred".
# So is a release whose date cannot be established -- a 404, an unreachable
# API, a date that does not parse: the cooldown fails closed, rather than
# letting a version through on the strength of a lookup that failed. The
# release date of a GitHub release is the later of its publication and the
# newest upload of any of its assets, so an asset replaced after publication
# restarts the clock.
#
# Units are independent. Each is resolved in full, its edits staged on copies,
# and the real files written only once every edit for that unit succeeded; a
# failure in one unit is reported and never touches another unit's files.
#
# Offline testing: BUMP_PINS_FIXTURES=<dir> answers every HTTP request from
# <dir>/urls (lines of "<url> <file>", or "<url> @404"), and fails on any URL
# not listed there rather than falling through to the network. BUMP_PINS_NOW
# (epoch seconds) fixes "now" for the cooldown. In fixture mode only,
# BUMP_PINS_KEYS (a directory) and BUMP_PINS_KEY_FPR stand in for scripts/keys
# and the pinned signing-key fingerprint, so the tests can sign with a
# throwaway key. See scripts/test-bump-pins.sh.
#
# `--check` reads the tables below against the tree and touches nothing, with
# no network: every pin, checksum and tofu row must name exactly one line that
# exists, so a renamed ARG cannot quietly drop a checksum from the bumps.
#
# Exit codes:
#   0  every unit was bumped, already current, or deferred (--check: tables ok)
#   1  at least one unit failed (the others were still processed)
#   2  bad usage
set -euo pipefail

readonly TIMEOUT=25
readonly RETRIES=2
# A tofu download is a whole release artifact (gcloud's is ~90 MB), not a
# checksums file, so it gets its own, longer deadline.
readonly DOWNLOAD_TIMEOUT=900

cooldown_days=${BUMP_COOLDOWN_DAYS:-7}
fixtures=${BUMP_PINS_FIXTURES:-}
now=${BUMP_PINS_NOW:-$(date -u +%s)}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/.." && pwd)
format=table
drift_file=""
unit_arg=""
to_arg=""
plan=0
check=0
log_level=info

usage() {
  cat <<'EOF'
usage: bump-pins.sh (--drift FILE | --unit NAME [--to VERSION] | --check) [options]

  --drift FILE   a `check-pins.sh --format json` report; bump every row that is behind
  --unit NAME    bump one unit (see UNITS below) to --to, or to the vendor's latest
  --to VERSION   the version to bump --unit to
  --plan         with --drift: print one JSON line per unit to bump, and edit nothing
  --check        verify the tables below against --root (no network, no edits)
  --root DIR     the tree to edit (default: this script's repository)
  --format F     table (default) or json, on stdout
  --quiet        suppress progress logging on stderr

Exit: 0 ok, 1 a unit failed, 2 usage.
EOF
}

log() {
  local level="$1"; shift
  [ "$log_level" = quiet ] && [ "$level" = info ] && return 0
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --drift)  [ $# -ge 2 ] || { echo "error: --drift needs a file" >&2; exit 2; }; drift_file="$2"; shift 2 ;;
    --unit)   [ $# -ge 2 ] || { echo "error: --unit needs a name" >&2; exit 2; }; unit_arg="$2"; shift 2 ;;
    --to)     [ $# -ge 2 ] || { echo "error: --to needs a version" >&2; exit 2; }; to_arg="$2"; shift 2 ;;
    --root)   [ $# -ge 2 ] || { echo "error: --root needs a directory" >&2; exit 2; }; root="$2"; shift 2 ;;
    --format) [ $# -ge 2 ] || { echo "error: --format needs a value" >&2; exit 2; }; format="$2"; shift 2 ;;
    --plan)   plan=1; shift ;;
    --check)  check=1; shift ;;
    --quiet)  log_level=quiet; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$format" in table|json) ;; *) echo "error: --format must be table or json" >&2; exit 2 ;; esac
if [ -n "$drift_file" ] && [ -n "$unit_arg" ]; then
  echo "error: --drift and --unit are mutually exclusive" >&2; exit 2
fi
if [ "$check" -eq 1 ] && { [ -n "$drift_file" ] || [ -n "$unit_arg" ]; }; then
  echo "error: --check takes no --drift or --unit" >&2; exit 2
fi
if [ "$check" -eq 0 ] && [ -z "$drift_file" ] && [ -z "$unit_arg" ]; then
  echo "error: one of --drift, --unit or --check is required" >&2; usage >&2; exit 2
fi
if [ -n "$to_arg" ] && [ -z "$unit_arg" ]; then
  echo "error: --to needs --unit" >&2; exit 2
fi
if [ "$plan" -eq 1 ] && [ -z "$drift_file" ]; then
  echo "error: --plan needs --drift" >&2; exit 2
fi
case "$cooldown_days" in ''|*[!0-9]*) echo "error: BUMP_COOLDOWN_DAYS must be a whole number" >&2; exit 2 ;; esac
case "$now" in ''|*[!0-9]*) echo "error: BUMP_PINS_NOW must be epoch seconds" >&2; exit 2 ;; esac
[ -d "$root" ] || { echo "error: --root $root is not a directory" >&2; exit 2; }
root=$(cd -- "$root" && pwd)
if [ -n "$fixtures" ]; then
  [ -f "$fixtures/urls" ] || { echo "error: BUMP_PINS_FIXTURES=$fixtures has no urls file" >&2; exit 2; }
  fixtures=$(cd -- "$fixtures" && pwd)
fi

for cmd in curl jq sort grep sed awk mktemp; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# --- the units ---------------------------------------------------------------
# unit | check-pins tool names | version pins (file:KEY ...) | integrity | release date | release page
#
# integrity:  sums           every checksum is a SUMS row below
#             tofu           the vendor publishes no checksum: each TOFU row
#                            below is the sha256 of our own download of that
#                            artifact (and a SIGS row, where there is one, a
#                            vendor signature checked first)
#             npm:<package>  the registry's integrity digest, which the
#                            npm client itself verifies on install
#             rubygems:<gem> the registry's sha256 for the .gem
#             pypi:<project> PyPI's sha256 for every wheel a linux amd64 or
#                            arm64 CPython can install; a pin in a `.txt`
#                            requirements file is rewritten with them as
#                            `--hash=` lines, for pip --require-hashes
# release date (for the cooldown):
#             github:<owner/repo>:<tag>, hashicorp:<product>, npm:<package>,
#             rubygems:<gem>, pypi:<project>, or first-seen (no vendor date:
#             the pin-bump PR's own first-seen clock is the cooldown)
#
# A pin is `file:KEY`: a Dockerfile `ARG KEY=`, a shell `KEY=`, a workflow
# `KEY:` -- or, in a `.txt` requirements file, the `<project>==` line, KEY
# being the project name as written there.
#
# {v} is replaced by the target version everywhere.
readonly UNITS='
terraform   | terraform           | ci-tools/Dockerfile.ci:TERRAFORM_VERSION | sums | hashicorp:terraform | https://releases.hashicorp.com/terraform/{v}/
kubectl     | kubectl             | ci-tools/Dockerfile.ci:KUBECTL_VERSION ci-cloud/Dockerfile.ci:KUBECTL_VERSION | sums | github:kubernetes/kubernetes:v{v} | https://github.com/kubernetes/kubernetes/releases/tag/v{v}
awscli      | awscli              | ci-tools/Dockerfile.ci:AWSCLI_VERSION | tofu | first-seen | https://github.com/aws/aws-cli/blob/{v}/CHANGELOG.rst
docker      | docker              | ci-tools/Dockerfile.ci:DOCKER_VERSION | tofu | first-seen | https://docs.docker.com/engine/release-notes/
gcloud      | gcloud              | ci-cloud/Dockerfile.ci:GCLOUD_VERSION | tofu | first-seen | https://cloud.google.com/sdk/docs/release-notes
az-pyjwt    | az-pyjwt            | ci-cloud/az-overrides.txt:pyjwt | pypi:PyJWT | pypi:PyJWT | https://pypi.org/project/PyJWT/{v}/
az-cryptography | az-cryptography | ci-cloud/az-overrides.txt:cryptography | pypi:cryptography | pypi:cryptography | https://pypi.org/project/cryptography/{v}/
az-pyopenssl | az-pyopenssl       | ci-cloud/az-overrides.txt:pyopenssl | pypi:pyOpenSSL | pypi:pyOpenSSL | https://pypi.org/project/pyOpenSSL/{v}/
az-urllib3  | az-urllib3          | ci-cloud/az-overrides.txt:urllib3 | pypi:urllib3 | pypi:urllib3 | https://pypi.org/project/urllib3/{v}/
zizmor      | zizmor              | .github/zizmor-requirements.txt:zizmor | pypi:zizmor | pypi:zizmor | https://pypi.org/project/zizmor/{v}/
playwright  | playwright          | */Dockerfile.ci:PLAYWRIGHT_VERSION | npm:playwright | npm:playwright | https://www.npmjs.com/package/playwright/v/{v}
npm         | npm                 | */Dockerfile.ci:NPM_VERSION | npm:npm | npm:npm | https://www.npmjs.com/package/npm/v/{v}
npm-brace-expansion | npm-brace-expansion | */Dockerfile.ci:NPM_BRACE_EXPANSION_VERSION | npm:brace-expansion | npm:brace-expansion | https://www.npmjs.com/package/brace-expansion/v/{v}
npm-undici  | npm-undici          | */Dockerfile.ci:NPM_UNDICI_VERSION | npm:undici | npm:undici | https://www.npmjs.com/package/undici/v/{v}
composer    | composer            | */Dockerfile.ci:COMPOSER_VERSION | sums | github:composer/composer:{v} | https://github.com/composer/composer/releases/tag/{v}
trivy       | trivy               | ci-security/Dockerfile.ci:TRIVY_VERSION | sums | github:aquasecurity/trivy:v{v} | https://github.com/aquasecurity/trivy/releases/tag/v{v}
syft        | syft                | ci-security/Dockerfile.ci:SYFT_VERSION | sums | github:anchore/syft:v{v} | https://github.com/anchore/syft/releases/tag/v{v}
grype       | grype               | ci-security/Dockerfile.ci:GRYPE_VERSION | sums | github:anchore/grype:v{v} | https://github.com/anchore/grype/releases/tag/v{v}
cosign      | cosign              | ci-security/Dockerfile.ci:COSIGN_VERSION | sums | github:sigstore/cosign:v{v} | https://github.com/sigstore/cosign/releases/tag/v{v}
gitleaks    | gitleaks,gitleaks-workflow | ci-security/Dockerfile.ci:GITLEAKS_VERSION .github/workflows/security.yml:GITLEAKS_VERSION | sums | github:gitleaks/gitleaks:v{v} | https://github.com/gitleaks/gitleaks/releases/tag/v{v}
migrate     | migrate             | ci-db/Dockerfile.ci:MIGRATE_VERSION | sums | github:golang-migrate/migrate:v{v} | https://github.com/golang-migrate/migrate/releases/tag/v{v}
osv-scanner | osv-scanner         | .github/workflows/build-image.yml:OSV_SCANNER_VERSION | sums | github:google/osv-scanner:v{v} | https://github.com/google/osv-scanner/releases/tag/v{v}
json        | json                | */Dockerfile.ci:JSON_VERSION | rubygems:json | rubygems:json | https://rubygems.org/gems/json/versions/{v}
hadolint    | hadolint            | scripts/lint.sh:HADOLINT_VERSION | sums | github:hadolint/hadolint:v{v} | https://github.com/hadolint/hadolint/releases/tag/v{v}
actionlint  | actionlint          | scripts/lint.sh:ACTIONLINT_VERSION | sums | github:rhysd/actionlint:v{v} | https://github.com/rhysd/actionlint/releases/tag/v{v}
'

# unit | file:KEY the checksum is written to | vendor checksum URL | name in that file ("-": the file is one bare hash)
#
# The names are the vendor's asset names, which each Dockerfile's download URL
# spells the same way; a name missing from the vendor's file is an error, not
# a guess.
readonly GH=https://github.com
readonly SUMS="
terraform   | ci-tools/Dockerfile.ci:TERRAFORM_SHA256_AMD64 | https://releases.hashicorp.com/terraform/{v}/terraform_{v}_SHA256SUMS | terraform_{v}_linux_amd64.zip
terraform   | ci-tools/Dockerfile.ci:TERRAFORM_SHA256_ARM64 | https://releases.hashicorp.com/terraform/{v}/terraform_{v}_SHA256SUMS | terraform_{v}_linux_arm64.zip
kubectl     | ci-tools/Dockerfile.ci:KUBECTL_SHA256_AMD64   | https://dl.k8s.io/release/v{v}/bin/linux/amd64/kubectl.sha256 | -
kubectl     | ci-tools/Dockerfile.ci:KUBECTL_SHA256_ARM64   | https://dl.k8s.io/release/v{v}/bin/linux/arm64/kubectl.sha256 | -
kubectl     | ci-cloud/Dockerfile.ci:KUBECTL_SHA256_AMD64   | https://dl.k8s.io/release/v{v}/bin/linux/amd64/kubectl.sha256 | -
kubectl     | ci-cloud/Dockerfile.ci:KUBECTL_SHA256_ARM64   | https://dl.k8s.io/release/v{v}/bin/linux/arm64/kubectl.sha256 | -
composer    | */Dockerfile.ci:COMPOSER_SHA256               | https://getcomposer.org/download/{v}/composer.phar.sha256sum | composer.phar
trivy       | ci-security/Dockerfile.ci:TRIVY_SHA256_AMD64  | $GH/aquasecurity/trivy/releases/download/v{v}/trivy_{v}_checksums.txt | trivy_{v}_Linux-64bit.tar.gz
trivy       | ci-security/Dockerfile.ci:TRIVY_SHA256_ARM64  | $GH/aquasecurity/trivy/releases/download/v{v}/trivy_{v}_checksums.txt | trivy_{v}_Linux-ARM64.tar.gz
syft        | ci-security/Dockerfile.ci:SYFT_SHA256_AMD64   | $GH/anchore/syft/releases/download/v{v}/syft_{v}_checksums.txt | syft_{v}_linux_amd64.tar.gz
syft        | ci-security/Dockerfile.ci:SYFT_SHA256_ARM64   | $GH/anchore/syft/releases/download/v{v}/syft_{v}_checksums.txt | syft_{v}_linux_arm64.tar.gz
grype       | ci-security/Dockerfile.ci:GRYPE_SHA256_AMD64  | $GH/anchore/grype/releases/download/v{v}/grype_{v}_checksums.txt | grype_{v}_linux_amd64.tar.gz
grype       | ci-security/Dockerfile.ci:GRYPE_SHA256_ARM64  | $GH/anchore/grype/releases/download/v{v}/grype_{v}_checksums.txt | grype_{v}_linux_arm64.tar.gz
cosign      | ci-security/Dockerfile.ci:COSIGN_SHA256_AMD64 | $GH/sigstore/cosign/releases/download/v{v}/cosign_checksums.txt | cosign-linux-amd64
cosign      | ci-security/Dockerfile.ci:COSIGN_SHA256_ARM64 | $GH/sigstore/cosign/releases/download/v{v}/cosign_checksums.txt | cosign-linux-arm64
gitleaks    | ci-security/Dockerfile.ci:GITLEAKS_SHA256_AMD64 | $GH/gitleaks/gitleaks/releases/download/v{v}/gitleaks_{v}_checksums.txt | gitleaks_{v}_linux_x64.tar.gz
gitleaks    | ci-security/Dockerfile.ci:GITLEAKS_SHA256_ARM64 | $GH/gitleaks/gitleaks/releases/download/v{v}/gitleaks_{v}_checksums.txt | gitleaks_{v}_linux_arm64.tar.gz
gitleaks    | .github/workflows/security.yml:GITLEAKS_SHA256  | $GH/gitleaks/gitleaks/releases/download/v{v}/gitleaks_{v}_checksums.txt | gitleaks_{v}_linux_x64.tar.gz
migrate     | ci-db/Dockerfile.ci:MIGRATE_SHA256_AMD64      | $GH/golang-migrate/migrate/releases/download/v{v}/sha256sum.txt | migrate.linux-amd64.tar.gz
migrate     | ci-db/Dockerfile.ci:MIGRATE_SHA256_ARM64      | $GH/golang-migrate/migrate/releases/download/v{v}/sha256sum.txt | migrate.linux-arm64.tar.gz
osv-scanner | .github/workflows/build-image.yml:OSV_SCANNER_SHA256 | $GH/google/osv-scanner/releases/download/v{v}/osv-scanner_SHA256SUMS | osv-scanner_linux_amd64
hadolint    | scripts/lint.sh:HADOLINT_SHA256_LINUX_X86_64  | $GH/hadolint/hadolint/releases/download/v{v}/checksums.sha256 | hadolint-linux-x86_64
hadolint    | scripts/lint.sh:HADOLINT_SHA256_LINUX_ARM64   | $GH/hadolint/hadolint/releases/download/v{v}/checksums.sha256 | hadolint-linux-arm64
hadolint    | scripts/lint.sh:HADOLINT_SHA256_MACOS_ARM64   | $GH/hadolint/hadolint/releases/download/v{v}/checksums.sha256 | hadolint-macos-arm64
hadolint    | scripts/lint.sh:HADOLINT_SHA256_MACOS_X86_64  | $GH/hadolint/hadolint/releases/download/v{v}/checksums.sha256 | hadolint-macos-x86_64
actionlint  | scripts/lint.sh:ACTIONLINT_SHA256_LINUX_AMD64  | $GH/rhysd/actionlint/releases/download/v{v}/actionlint_{v}_checksums.txt | actionlint_{v}_linux_amd64.tar.gz
actionlint  | scripts/lint.sh:ACTIONLINT_SHA256_LINUX_ARM64  | $GH/rhysd/actionlint/releases/download/v{v}/actionlint_{v}_checksums.txt | actionlint_{v}_linux_arm64.tar.gz
actionlint  | scripts/lint.sh:ACTIONLINT_SHA256_DARWIN_AMD64 | $GH/rhysd/actionlint/releases/download/v{v}/actionlint_{v}_checksums.txt | actionlint_{v}_darwin_amd64.tar.gz
actionlint  | scripts/lint.sh:ACTIONLINT_SHA256_DARWIN_ARM64 | $GH/rhysd/actionlint/releases/download/v{v}/actionlint_{v}_checksums.txt | actionlint_{v}_darwin_arm64.tar.gz
"

# unit | file:KEY the hash is written to | the artifact, exactly as the
# Dockerfile downloads it. For the tools with no vendor checksum: the artifact
# is downloaded and hashed (trust on first use; see the header). Both
# architectures, since each is its own download -- which also catches a
# version the resolver misread, here rather than as a 404 halfway through a
# multi-arch build.
readonly TOFU='
awscli | ci-tools/Dockerfile.ci:AWSCLI_SHA256_AMD64 | https://awscli.amazonaws.com/awscli-exe-linux-x86_64-{v}.zip
awscli | ci-tools/Dockerfile.ci:AWSCLI_SHA256_ARM64 | https://awscli.amazonaws.com/awscli-exe-linux-aarch64-{v}.zip
docker | ci-tools/Dockerfile.ci:DOCKER_SHA256_AMD64 | https://download.docker.com/linux/static/stable/x86_64/docker-{v}.tgz
docker | ci-tools/Dockerfile.ci:DOCKER_SHA256_ARM64 | https://download.docker.com/linux/static/stable/aarch64/docker-{v}.tgz
gcloud | ci-cloud/Dockerfile.ci:GCLOUD_SHA256_AMD64 | https://storage.googleapis.com/cloud-sdk-release/google-cloud-cli-{v}-linux-x86_64.tar.gz
gcloud | ci-cloud/Dockerfile.ci:GCLOUD_SHA256_ARM64 | https://storage.googleapis.com/cloud-sdk-release/google-cloud-cli-{v}-linux-arm.tar.gz
'

# unit | a TOFU artifact URL | its detached signature | key file in scripts/keys | primary key fingerprint
#
# Checked before the artifact's hash is recorded: `gpgv` must report a valid
# signature by exactly this key (an expired key still counts -- AWS lets the
# expiry of its CLI key lapse between renewals, and the signature is no less
# AWS's for it -- a revoked one does not). The key file is AWS's published
# "AWS CLI Team" key; the fingerprint is the one AWS documents for it, and the
# key file must carry it, so swapping the file alone changes nothing. A new
# AWS key fails the bump, for a human to check and pin.
readonly SIGS='
awscli | https://awscli.amazonaws.com/awscli-exe-linux-x86_64-{v}.zip  | https://awscli.amazonaws.com/awscli-exe-linux-x86_64-{v}.zip.sig  | aws-cli.asc | FB5DB77FD5C118B80511ADA8A6310ACC4672475C
awscli | https://awscli.amazonaws.com/awscli-exe-linux-aarch64-{v}.zip | https://awscli.amazonaws.com/awscli-exe-linux-aarch64-{v}.zip.sig | aws-cli.asc | FB5DB77FD5C118B80511ADA8A6310ACC4672475C
'

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# expand_pins SPEC... -- the pins a UNITS or SUMS spec names. `*/Dockerfile.ci:KEY`
# is every image in the tree's .github/images.json whose Dockerfile.ci pins KEY,
# in images.json order; anything else is itself. Prints nothing for a `*` spec
# no image carries, which the caller reports.
expand_pins() {
  local spec key img
  for spec in "$@"; do
    case "$spec" in
      '*/Dockerfile.ci:'*)
        key=${spec#*:}
        for img in $(jq -r '.[].image' "$root/.github/images.json" 2>/dev/null); do
          grep -q "^ARG $key=" "$root/$img/Dockerfile.ci" 2>/dev/null && printf '%s\n' "$img/Dockerfile.ci:$key"
        done ;;
      *) printf '%s\n' "$spec" ;;
    esac
  done
  return 0
}
subst() { printf '%s' "${1//\{v\}/$2}"; }

# unit_field UNIT N -- column N (1-based) of the unit's UNITS row.
unit_field() {
  local unit="$1" n="$2" line
  line=$(printf '%s\n' "$UNITS" | awk -F'|' -v u="$unit" '{ x=$1; gsub(/[[:space:]]/, "", x); if (x == u) { print; exit } }')
  [ -n "$line" ] || return 1
  trim "$(printf '%s' "$line" | cut -d'|' -f"$n")"
}

unit_for_tool() {
  local tool="$1"
  printf '%s\n' "$UNITS" | awk -F'|' -v t="$tool" '
    NF >= 6 {
      u=$1; gsub(/[[:space:]]/, "", u); ts=$2; gsub(/[[:space:]]/, "", ts)
      n = split(ts, a, ","); for (i = 1; i <= n; i++) if (a[i] == t) { print u; exit }
    }'
}

# --- HTTP, with the fixture switch --------------------------------------------
# Every request goes through here, so the offline tests exercise the same
# parsing code the real run does, fed the vendor's real file formats.
fixture_for() {
  awk -v u="$1" '$1 == u { print $2; found=1; exit } END { exit !found }' "$fixtures/urls"
}

# Exit 99, and only here, for a URL with no fixture: the one failure that is a
# broken test rather than a vendor's answer, so a caller that otherwise treats
# a failed lookup as "unknown" (the release date) can still fail loudly on it.
readonly NO_FIXTURE=99
http_get() {
  local url="$1" f auth=()
  if [ -n "$fixtures" ]; then
    if ! f=$(fixture_for "$url"); then
      log error "no fixture for $url -- refusing to reach the network in fixture mode"
      return "$NO_FIXTURE"
    fi
    [ "$f" = "@404" ] && return 22
    cat "$fixtures/$f"
    return 0
  fi
  # GITHUB_TOKEN from the environment only, never echoed; unauthenticated API
  # calls are limited to 60 an hour, which one full run can exceed.
  case "$url" in
    https://api.github.com/*)
      [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
      auth+=(-H 'Accept: application/vnd.github+json') ;;
  esac
  curl -fsSL --retry "$RETRIES" --retry-all-errors --max-time "$TIMEOUT" "${auth[@]}" "$url"
}

# http_download URL DEST -- a whole artifact, to a file rather than through a
# variable (they are tens of megabytes, and binary).
http_download() {
  local url="$1" dest="$2" f
  if [ -n "$fixtures" ]; then
    if ! f=$(fixture_for "$url"); then
      log error "no fixture for $url -- refusing to reach the network in fixture mode"
      return "$NO_FIXTURE"
    fi
    [ "$f" = "@404" ] && return 22
    cp "$fixtures/$f" "$dest"
    return 0
  fi
  curl -fsSL --retry "$RETRIES" --retry-all-errors --max-time "$DOWNLOAD_TIMEOUT" -o "$dest" "$url"
}

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# verify_sig UNIT URL FILE -- 0 when no SIGS row covers URL, or when its
# signature verifies under the pinned key; 1, with the reason logged, when not.
verify_sig() {
  local unit="$1" url="$2" file="$3" row_unit row_url row_sig row_key row_fpr
  local sig_url keyfile fpr keydir status cmd
  while IFS='|' read -r row_unit row_url row_sig row_key row_fpr; do
    [ "$(trim "$row_unit")" = "$unit" ] || continue
    [ "$(subst "$(trim "$row_url")" "$new")" = "$url" ] || continue
    sig_url=$(subst "$(trim "$row_sig")" "$new")
    keydir="$script_dir/keys"; fpr=$(trim "$row_fpr")
    if [ -n "$fixtures" ]; then
      keydir=${BUMP_PINS_KEYS:-$keydir}; fpr=${BUMP_PINS_KEY_FPR:-$fpr}
    fi
    keyfile="$keydir/$(trim "$row_key")"
    for cmd in gpg gpgv; do
      command -v "$cmd" >/dev/null || { log error "$cmd is needed to verify $sig_url"; return 1; }
    done
    [ -f "$keyfile" ] || { log error "signing key $keyfile is missing"; return 1; }
    # A private GNUPGHOME: nothing is read from, or left in, the runner's own.
    mkdir -p "$tmp/gnupg"; chmod 700 "$tmp/gnupg"
    if [ "$(GNUPGHOME="$tmp/gnupg" gpg --batch --show-keys --with-colons "$keyfile" 2>/dev/null \
            | awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print $10; p = 0 }')" != "$fpr" ]; then
      log error "$keyfile is not exactly the key $fpr"
      return 1
    fi
    GNUPGHOME="$tmp/gnupg" gpg --batch --yes --dearmor -o "$tmp/sigkey.gpg" "$keyfile" 2>/dev/null \
      || { log error "could not read $keyfile"; return 1; }
    http_download "$sig_url" "$tmp/artifact.sig" || { log error "no signature at $sig_url"; return 1; }
    status=$(GNUPGHOME="$tmp/gnupg" gpgv --status-fd 1 --keyring "$tmp/sigkey.gpg" "$tmp/artifact.sig" "$file" 2>/dev/null) \
      || { log error "$sig_url does not verify $url under $fpr"; return 1; }
    if printf '%s\n' "$status" | grep -qE '^\[GNUPG:\] (REVKEYSIG|BADSIG|ERRSIG)'; then
      log error "$sig_url: the key is revoked, or the signature is bad"
      return 1
    fi
    if ! printf '%s\n' "$status" | awk -v f="$fpr" '$2 == "VALIDSIG" && ($3 == f || $NF == f) { ok = 1 } END { exit !ok }'; then
      log error "$sig_url is not a valid signature by $fpr"
      return 1
    fi
    integrity_urls+=("$sig_url")
    log info "$unit: $url verifies under $fpr"
  done <<< "$SIGS"
  return 0
}

# Cached per URL: several SUMS rows read the same checksums file.
get_cached() {
  local url="$1" key
  key=$(printf '%s' "$url" | cksum | cut -d' ' -f1)
  if [ ! -f "$tmp/cache.$key" ]; then
    local rc=0
    http_get "$url" > "$tmp/cache.$key.part" || rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$tmp/cache.$key.part"; return "$rc"; }
    mv "$tmp/cache.$key.part" "$tmp/cache.$key"
  fi
  cat "$tmp/cache.$key"
}

is_sha256() { printf '%s' "$1" | grep -qxE '[0-9a-f]{64}'; }

# sum_from URL NAME -- the one sha256 the vendor's file lists for NAME. Handles
# `<hex>  <name>` and `<hex> *<name>` (binary-mode marker), CRLF line ends, and
# a bare single-hash file when NAME is "-". Exactly one match, or it fails.
# A line that names the asset but is not `<hex> <name>` (a bare file: not one
# lone field) is an error too, rather than skipped: skipping it could leave a
# different line as the "one" match, in a file whose format is not what this
# parser was written for.
sum_from() {
  local url="$1" name="$2" body matches malformed
  body=$(get_cached "$url" | tr -d '\r') || return 1
  if [ "$name" = "-" ]; then
    malformed=$(printf '%s\n' "$body" | awk 'NF > 1 { print NR }' | head -1)
    matches=$(printf '%s\n' "$body" | awk 'NF { print $1 }')
  else
    malformed=$(printf '%s\n' "$body" | awk -v n="$name" '
      NF != 2 { for (i = 1; i <= NF; i++) { f=$i; sub(/^\*/, "", f); if (f == n) { print NR; exit } } }')
    matches=$(printf '%s\n' "$body" | awk -v n="$name" '{ f=$2; sub(/^\*/, "", f); if (NF == 2 && f == n) print $1 }')
  fi
  if [ -n "$malformed" ]; then
    log error "line $malformed of $url is not in the expected checksum format"
    return 1
  fi
  if [ "$(printf '%s' "$matches" | grep -c .)" -ne 1 ]; then
    log error "expected exactly one checksum for '$name' in $url, found $(printf '%s' "$matches" | grep -c .)"
    return 1
  fi
  if ! is_sha256 "$matches"; then
    log error "'$matches' from $url is not a sha256"
    return 1
  fi
  printf '%s' "$matches"
}

# release_date SPEC VERSION -- ISO 8601, or empty when it cannot be found.
# Fails with NO_FIXTURE when a fixture is missing (see http_get).
#
# A GitHub release's date is the later of published_at and every asset's
# updated_at: an asset uploaded or replaced after the release was published
# is a new artifact under an old date, and restarts the cooldown. A PyPI
# release's is its newest file upload, for the same reason.
release_date() {
  local spec="$1" v="$2" kind rest repo tag body rc=0
  kind=${spec%%:*}; rest=${spec#*:}
  case "$kind" in
    github)
      repo=${rest%%:*}; tag=$(subst "${rest#*:}" "$v")
      body=$(http_get "https://api.github.com/repos/$repo/releases/tags/$tag") || rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      jq -r '[.published_at, (.assets // [])[].updated_at] | map(strings) | max // empty' <<<"$body" ;;
    hashicorp)
      body=$(http_get "https://api.releases.hashicorp.com/v1/releases/$rest/$v") || rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      jq -r '.timestamp_created // empty' <<<"$body" ;;
    npm)
      body=$(get_cached "https://registry.npmjs.org/$rest") || rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      jq -r --arg v "$v" '.time[$v] // empty' <<<"$body" ;;
    rubygems)
      body=$(get_cached "https://rubygems.org/api/v1/versions/$rest.json") || rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      jq -r --arg v "$v" '[.[] | select(.number == $v and .platform == "ruby")][0].created_at // empty' <<<"$body" ;;
    pypi)
      body=$(get_cached "https://pypi.org/pypi/$rest/$v/json") || rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      jq -r '[(.urls // [])[].upload_time_iso_8601] | map(strings) | max // empty' <<<"$body" ;;
    *) return 1 ;;
  esac
}

# pypi_hashes PROJECT VERSION -- the sha256 of every wheel of that release a
# CPython on linux amd64 or arm64 can install (pure-Python, or a glibc
# manylinux wheel for x86_64/aarch64, any abi3 or plain cp3XX ABI), sorted,
# one per line. sdists are left out: the installs that use these run with
# --only-binary :all:, so nothing is ever built from source. Fails when a
# selected file is yanked, or when the release has no wheel for one of the
# two architectures -- either way an image build would fail later, and less
# clearly.
pypi_hashes() {
  local body
  body=$(get_cached "https://pypi.org/pypi/$1/$2/json") || return 1
  jq -r '
    [(.urls // [])[] | select(.packagetype == "bdist_wheel"
       and (.filename | test("-(py3|py2\\.py3|cp3[0-9]+)-(none|abi3|cp3[0-9]+)-(any|manylinux[0-9a-z_.]*(x86_64|aarch64))\\.whl$")))]
    | if length == 0 then error("no linux wheel")
      elif any(.[]; .yanked) then error("a selected file is yanked")
      elif (any(.[]; .filename | endswith("-any.whl")) | not)
           and ((any(.[]; .filename | endswith("x86_64.whl")) and any(.[]; .filename | endswith("aarch64.whl"))) | not)
        then error("no wheel for one of x86_64 and aarch64")
      else [.[].digests.sha256] end
    | if all(.[]; type == "string" and test("^[0-9a-f]{64}$")) then . else error("not a sha256") end
    | unique[]' <<<"$body"
}

iso_to_epoch() { jq -rn --arg d "$1" '$d | sub("\\.[0-9]+"; "") | fromdateiso8601'; }

is_version() { printf '%s' "$1" | grep -qxE '[0-9]+(\.[0-9]+)*'; }
# 0 when $1 sorts strictly after $2.
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# --- reading and writing a pin -----------------------------------------------
# The three spellings check-pins.sh reads: a Dockerfile `ARG KEY=v`, a shell
# `KEY=v` at the start of a line, and a workflow `env:` entry `    KEY: v`.
# And a fourth, in a `.txt` requirements file: `KEY==v`, followed by its
# `--hash=` continuation lines (see set_req).
get_pin() {
  local file="$1" key="$2"
  case "$file" in
    *.txt)
      grep -m1 -E "^${key}==" "$file" 2>/dev/null | sed -E "s/^${key}==//;s/[[:space:]].*$//" || true
      return 0 ;;
  esac
  grep -m1 -E "^(ARG )?${key}=|^[[:space:]]+${key}:[[:space:]]" "$file" 2>/dev/null \
    | sed -E "s/^ARG //;s/^${key}=//;s/^[[:space:]]+${key}:[[:space:]]*//;s/[[:space:]].*$//" || true
}

# pin_lines FILE KEY -- how many lines carry the pin; set_pin needs exactly one.
pin_lines() {
  case "$1" in
    *.txt) grep -cE "^$2==" "$1" 2>/dev/null || true ;;
    *) grep -cE "^(ARG )?$2=|^[[:space:]]+$2:[[:space:]]+" "$1" 2>/dev/null || true ;;
  esac
}

# set_req FILE PROJECT VERSION HASHES -- rewrite one requirement and its hash
# lines: `PROJECT==VERSION \` and then one `--hash=sha256:<h>` per word of
# HASHES, each continued but the last. The old requirement's continuation
# lines go with it; everything else in the file (comments, other
# requirements) is kept as it is. Exactly one requirement line may match.
set_req() {
  local file="$1" key="$2" value="$3" hashes="$4" rc=0
  [ -n "$hashes" ] || { log error "$key: no hashes to write"; return 1; }
  awk -v key="$key" -v val="$value" -v hashes="$hashes" '
    skip { if ($0 !~ /\\[[:space:]]*$/) skip = 0; next }
    $0 ~ ("^" key "==") {
      n++
      k = split(hashes, h, " ")
      printf "%s==%s \\\n", key, val
      for (i = 1; i <= k; i++) printf "    --hash=sha256:%s%s\n", h[i], (i < k ? " \\" : "")
      if ($0 ~ /\\[[:space:]]*$/) skip = 1
      next
    }
    { print }
    END { if (n != 1) exit 3 }
  ' "$file" > "$file.new" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$file.new"
    log error "$key: expected exactly one requirement line in $(basename "$file"), rc=$rc"
    return 1
  fi
  cat "$file.new" > "$file"
  rm -f "$file.new"
  [ "$(get_pin "$file" "$key")" = "$value" ] || { log error "$key did not read back as $value"; return 1; }
}

# set_pin FILE KEY VALUE -- rewrite the value in place, keeping everything else
# on the line. Exactly one line may match: zero means the pin moved or was
# renamed, two means an edit here could silently leave a stale copy.
set_pin() {
  local file="$1" key="$2" value="$3" rc=0
  awk -v key="$key" -v val="$value" '
    function rewrite(line, plen,   rest, i) {
      rest = substr(line, plen + 1)
      i = match(rest, /[[:space:]]/)
      return substr(line, 1, plen) val (i ? substr(rest, i) : "")
    }
    match($0, "^ARG " key "=") || match($0, "^" key "=") || match($0, "^[[:space:]]+" key ":[[:space:]]+") {
      n++; print rewrite($0, RLENGTH); next
    }
    { print }
    END { if (n != 1) exit 3 }
  ' "$file" > "$file.new" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$file.new"
    log error "$key: expected exactly one pin line in $(basename "$file"), rc=$rc"
    return 1
  fi
  cat "$file.new" > "$file"   # cat, not mv: keeps the file's mode (lint.sh is executable)
  rm -f "$file.new"
  [ "$(get_pin "$file" "$key")" = "$value" ] || { log error "$key did not read back as $value"; return 1; }
}

# --- one unit ----------------------------------------------------------------
edited_files=(); integrity_urls=(); pin_values=()
results="$tmp/results.jsonl"
: > "$results"
errors=0

emit() {
  # emit UNIT STATUS OLD NEW CLASS REASON ERROR
  #
  # `pins` is every value written, as file:KEY=value (a requirement's hashes
  # as file:KEY#sha256=h1,h2,...), sorted: scripts/pin-bump-prs.sh compares
  # it between two rebuilds of the same version, and restarts the first-seen
  # clock if a downloaded artifact's hash changed under an unchanged version.
  local files_json urls_json pins_json
  files_json=$(printf '%s\n' "${edited_files[@]:-}" | sed '/^$/d' | sort -u | jq -R . | jq -sc .)
  urls_json=$(printf '%s\n' "${integrity_urls[@]:-}" | sed '/^$/d' | sort -u | jq -R . | jq -sc .)
  pins_json=$(printf '%s\n' "${pin_values[@]:-}" | sed '/^$/d' | LC_ALL=C sort -u | jq -R . | jq -sc .)
  jq -nc --arg unit "$1" --arg status "$2" --arg old "$3" --arg new "$4" \
    --arg class "$5" --arg reason "$6" --arg error "$7" \
    --arg tools "$(unit_field "$1" 2 2>/dev/null || true)" \
    --arg integrity "$(unit_field "$1" 4 2>/dev/null || true)" \
    --arg cooldown "$(if [ "$(unit_field "$1" 5 2>/dev/null || true)" = first-seen ]; then echo first-seen; else echo release-date; fi)" \
    --arg version_url "${version_url:-}" --arg released "${released:-}" \
    --argjson files "$files_json" --argjson integrity_urls "$urls_json" --argjson pins "$pins_json" \
    '{unit:$unit, tools:($tools | split(",") | map(select(length > 0))), status:$status,
      old:(if $old == "" then null else $old end), new:(if $new == "" then null else $new end),
      class:(if $class == "" then null else $class end), reason:$reason,
      error:(if $error == "" then null else $error end),
      integrity:(if $integrity == "" then null else ($integrity | sub(":.*"; "")) end),
      cooldown:(if $integrity == "" then null else $cooldown end),
      released:(if $released == "" then null else $released end),
      version_url:(if $version_url == "" then null else $version_url end),
      integrity_urls:$integrity_urls, files:$files, pins:$pins}' >> "$results"
}

fail_unit() {
  log error "$1: $2"
  errors=$((errors + 1))
  emit "$1" error "${old:-}" "${new:-}" "" "" "$2"
}

bump_unit() {
  local unit="$1" new="$2" pins integrity date_spec
  local old="" pin file key cur all_new=1 note=""
  edited_files=(); integrity_urls=(); pin_values=(); version_url=""; released=""

  pins=$(unit_field "$unit" 3) || { old=""; fail_unit "$unit" "unknown unit"; return 0; }
  # shellcheck disable=SC2086  # one spec per word
  pins=$(expand_pins $pins)
  [ -n "$pins" ] || { fail_unit "$unit" "no image in .github/images.json pins $(unit_field "$unit" 3)"; return 0; }
  integrity=$(unit_field "$unit" 4)
  date_spec=$(unit_field "$unit" 5)
  version_url=$(subst "$(unit_field "$unit" 6)" "$new")

  if ! is_version "$new"; then fail_unit "$unit" "target version '$new' is not a dotted number"; return 0; fi

  # Every copy of the pin is read. The first is the one check-pins reports.
  for pin in $pins; do
    file=${pin%%:*}; key=${pin#*:}
    [ -f "$root/$file" ] || { fail_unit "$unit" "$file does not exist"; return 0; }
    cur=$(get_pin "$root/$file" "$key")
    [ -n "$cur" ] || { fail_unit "$unit" "no $key in $file"; return 0; }
    [ -n "$old" ] || old=$cur
    [ "$cur" = "$old" ] || note="copies disagreed before this bump ($file had $cur); all now move together. "
    [ "$cur" = "$new" ] || all_new=0
  done

  if [ "$all_new" -eq 1 ]; then
    log info "$unit: already at $new"
    emit "$unit" current "$old" "$new" "" "already at $new" ""
    return 0
  fi
  if ! is_version "$old"; then fail_unit "$unit" "pinned version '$old' is not a dotted number"; return 0; fi
  if [ "$old" != "$new" ] && ! ver_gt "$new" "$old"; then
    fail_unit "$unit" "target $new is older than the pinned $old"; return 0
  fi

  # --- cooldown first: the cheapest check, and one that skips the rest.
  # A unit with a vendor release date waits until it is the cooldown old, and
  # a date that cannot be established defers the bump too: the cooldown is
  # only a control if it fails closed. The first-seen units have no vendor
  # date at all; their cooldown is the PR's own clock (see the header).
  local epoch age rc
  if [ "$date_spec" != first-seen ]; then
    rc=0; released=$(release_date "$date_spec" "$new") || rc=$?
    if [ "$rc" -eq "$NO_FIXTURE" ]; then
      released=""; fail_unit "$unit" "no fixture for the release date of $new"; return 0
    fi
    # Anchored before it is parsed: jq's fromdateiso8601 accepts trailing
    # text after a space, and this string is the vendor's -- it ends up in the
    # PR body, where a planted `<!-- pin-bump: ... -->` would be read as the
    # bot's own marker. Anything but a bare UTC timestamp is "unknown".
    if [ "$rc" -eq 0 ] && ! [[ "$released" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
      rc=65
    fi
    if [ "$rc" -ne 0 ] || [ -z "$released" ] || ! epoch=$(iso_to_epoch "$released" 2>/dev/null) || [ -z "$epoch" ]; then
      log info "$unit: could not establish the release date of $new (exit $rc, got '$(printf '%s' "$released" | tr -c 'A-Za-z0-9:.+-' '?' | cut -c1-40)'); deferred"
      released=""
      emit "$unit" deferred "$old" "$new" "" "release date unknown, so the ${cooldown_days}-day cooldown cannot be confirmed; not bumped until it can" ""
      return 0
    fi
    age=$(( (now - epoch) / 86400 ))
    if [ "$age" -lt "$cooldown_days" ]; then
      log info "$unit: $new was released $released, $age day(s) ago; deferred until it is $cooldown_days days old"
      emit "$unit" deferred "$old" "$new" "" "released $released, ${age}d ago; cooldown is ${cooldown_days}d" ""
      return 0
    fi
  fi

  # --- integrity: collect every edit before making any.
  local edits=() row sfile skey surl sname sum req_hashes=""
  for pin in $pins; do edits+=("$pin=$new"); done
  case "$integrity" in
    sums)
      while IFS='|' read -r row_unit row_pin row_url row_name; do
        [ "$(trim "$row_unit")" = "$unit" ] || continue
        surl=$(subst "$(trim "$row_url")" "$new"); sname=$(subst "$(trim "$row_name")" "$new")
        if ! sum=$(sum_from "$surl" "$sname"); then
          fail_unit "$unit" "no vendor checksum for $sname at $surl"; return 0
        fi
        integrity_urls+=("$surl")
        for row in $(expand_pins "$(trim "$row_pin")"); do
          sfile=${row%%:*}; skey=${row#*:}
          edits+=("$sfile:$skey=$sum")
        done
      done <<< "$SUMS"
      [ "${#integrity_urls[@]}" -gt 0 ] || { fail_unit "$unit" "integrity is 'sums' but no SUMS rows"; return 0; }
      ;;
    tofu)
      # Trust on first use: download each artifact, check its vendor
      # signature where there is one, and record the sha256 of what came.
      local dl="$tmp/artifact"
      while IFS='|' read -r row_unit row_pin row_url; do
        [ "$(trim "$row_unit")" = "$unit" ] || continue
        surl=$(subst "$(trim "$row_url")" "$new")
        rm -f "$dl"
        rc=0; http_download "$surl" "$dl" || rc=$?
        if [ "$rc" -ne 0 ]; then
          fail_unit "$unit" "could not download $surl (exit $rc); is $new a real release?"; return 0
        fi
        if ! verify_sig "$unit" "$surl" "$dl"; then
          rm -f "$dl"; fail_unit "$unit" "the vendor signature on $surl does not verify"; return 0
        fi
        sum=$(sha256_of "$dl"); rm -f "$dl"
        is_sha256 "$sum" || { fail_unit "$unit" "could not hash $surl"; return 0; }
        integrity_urls+=("$surl")
        for row in $(expand_pins "$(trim "$row_pin")"); do
          sfile=${row%%:*}; skey=${row#*:}
          edits+=("$sfile:$skey=$sum")
        done
      done <<< "$TOFU"
      [ "${#integrity_urls[@]}" -gt 0 ] || { fail_unit "$unit" "integrity is 'tofu' but no TOFU rows"; return 0; }
      ;;
    npm:*)
      local pkg=${integrity#npm:} doc_url integ
      doc_url="https://registry.npmjs.org/$pkg"
      integ=$(get_cached "$doc_url" | jq -r --arg v "$new" '.versions[$v].dist.integrity // empty' || true)
      case "$integ" in
        sha512-*) integrity_urls+=("https://registry.npmjs.org/$pkg/$new") ;;
        *) fail_unit "$unit" "the registry has no sha512 integrity for $pkg@$new"; return 0 ;;
      esac
      ;;
    rubygems:*)
      local gem=${integrity#rubygems:} gsha
      gsha=$(get_cached "https://rubygems.org/api/v1/versions/$gem.json" \
        | jq -r --arg v "$new" '[.[] | select(.number == $v and .platform == "ruby")][0].sha // empty' || true)
      is_sha256 "$gsha" || { fail_unit "$unit" "rubygems.org lists no sha256 for $gem $new"; return 0; }
      integrity_urls+=("https://rubygems.org/api/v1/versions/$gem.json")
      ;;
    pypi:*)
      local project=${integrity#pypi:}
      if ! req_hashes=$(pypi_hashes "$project" "$new" 2>/dev/null) || [ -z "$req_hashes" ]; then
        fail_unit "$unit" "PyPI lists no usable linux amd64 and arm64 wheels for $project $new (none, yanked, or one architecture missing)"; return 0
      fi
      req_hashes=$(printf '%s\n' "$req_hashes" | paste -sd' ' -)
      integrity_urls+=("https://pypi.org/pypi/$project/$new/json")
      ;;
    *) fail_unit "$unit" "unknown integrity kind '$integrity'"; return 0 ;;
  esac

  # --- classify
  local class=auto reason
  if [ "$integrity" = tofu ]; then
    class=review
    reason="the vendor publishes no checksum: sha256 recorded from our own download (trust on first use"
    case " ${integrity_urls[*]} " in *.sig\ *) reason="$reason, after the vendor signature verified" ;; esac
    reason="$reason); merges only once its PR has carried this version for ${cooldown_days} days (first-seen cooldown)"
  elif [ "${old%%.*}" != "${new%%.*}" ]; then
    class=review
    reason="major version change (${old%%.*} -> ${new%%.*}); released $released; merges only once its PR has carried this version for ${cooldown_days} days (first-seen cooldown)"
  else
    case "$integrity" in
      sums)   reason="checksums from the vendor's published checksum file" ;;
      npm:*)  reason="npm registry sha512 integrity, verified by npm on install" ;;
      pypi:*) reason="sha256 of every linux wheel from PyPI's JSON API, installed with pip --require-hashes" ;;
      *)      reason="registry-published sha256" ;;
    esac
    reason="$reason; not a major version; released $released"
  fi
  reason="$note$reason"

  # --- stage every edit on copies, then write the unit's files in one go.
  # Plain arrays rather than an associative one, so this runs on the bash 3.2
  # macOS ships: scripts/lint.sh runs its tests locally as well as in CI.
  local stage="$tmp/stage.$unit" edit target value copy staged=()
  rm -rf "$stage"; mkdir -p "$stage"
  for edit in "${edits[@]}"; do
    target=${edit%%=*}; value=${edit#*=}
    file=${target%%:*}; key=${target#*:}
    copy="$stage/$(printf '%s' "$file" | tr '/' '_')"
    if [ ! -f "$copy" ]; then
      cp "$root/$file" "$copy"
      staged+=("$file")
    fi
    case "$file" in
      *.txt)
        # A requirements file carries its hashes with the version, and only
        # PyPI's can go there.
        if [ -z "$req_hashes" ] || ! set_req "$copy" "$key" "$value" "$req_hashes"; then
          fail_unit "$unit" "could not set $key in $file"; return 0
        fi
        pin_values+=("$file:$key#sha256=${req_hashes// /,}") ;;
      *)
        if ! set_pin "$copy" "$key" "$value"; then
          fail_unit "$unit" "could not set $key in $file"; return 0
        fi ;;
    esac
    pin_values+=("$edit")
  done
  for file in "${staged[@]}"; do
    cat "$stage/$(printf '%s' "$file" | tr '/' '_')" > "$root/$file"
    edited_files+=("$file")
  done

  log info "$unit: $old -> $new ($class)"
  emit "$unit" bumped "$old" "$new" "$class" "$reason" ""
}

# --- --check: the tables against the tree ------------------------------------
# Every pin a unit names, every checksum row and every tofu row must be
# exactly one line in --root, holding a version or a sha256; every tofu unit
# must have its rows and every row a tofu unit; every signature row must match
# a tofu row and name a key file that exists. Read-only and offline, so
# scripts/test-bump-pins.sh runs it over the real tree on every lint: a
# renamed ARG fails there, not in a bump that silently skipped a checksum.
check_tables() {
  local bad=0 line u p f k n v spec specs integ urow
  complain() { log error "$*"; bad=$((bad + 1)); }
  one_line() { # FILE:KEY WHAT -- the pin is exactly one line; its value in $v
    f=${1%%:*}; k=${1#*:}
    [ -f "$root/$f" ] || { complain "$2 $1: $f does not exist"; return 1; }
    n=$(pin_lines "$root/$f" "$k")
    [ "$n" = 1 ] || { complain "$2 $1: $n lines carry it, not 1"; return 1; }
    v=$(get_pin "$root/$f" "$k")
  }
  while IFS='|' read -r u _ specs integ _; do
    u=$(trim "$u"); [ -n "$u" ] || continue
    integ=$(trim "$integ")
    # shellcheck disable=SC2086  # one spec per word
    for p in $(expand_pins $specs); do
      one_line "$p" "$u: pin" || continue
      is_version "$v" || complain "$u: pin $p is '$v', not a version"
      case "$p" in
        *.txt:*)
          case "$integ" in pypi:*) ;; *) complain "$u: $p is a requirements pin, but integrity is $integ" ;; esac
          awk -v k="${p#*:}" '$0 ~ ("^" k "==") { on = 1; next } on && /--hash=sha256:[0-9a-f]+/ { h++ } on && !/\\[[:space:]]*$/ { on = 0 } END { exit !h }' \
            "$root/${p%%:*}" || complain "$u: $p has no --hash=sha256 lines" ;;
      esac
    done
    if [ "$integ" = tofu ]; then
      printf '%s\n' "$TOFU" | awk -F'|' -v u="$u" '{ x = $1; gsub(/[[:space:]]/, "", x); if (x == u) f = 1 } END { exit !f }' \
        || complain "$u: integrity is tofu but there is no TOFU row"
    fi
  done <<< "$UNITS"
  while IFS='|' read -r u spec _; do
    u=$(trim "$u"); [ -n "$u" ] || continue
    for p in $(expand_pins "$(trim "$spec")"); do
      one_line "$p" "$u: checksum" || continue
      is_sha256 "$v" || complain "$u: checksum $p is '$v', not a sha256"
    done
  done <<< "$SUMS"
  while IFS='|' read -r u spec _; do
    u=$(trim "$u"); [ -n "$u" ] || continue
    [ "$(unit_field "$u" 4 2>/dev/null || true)" = tofu ] || complain "TOFU row for $u, which is not a tofu unit"
    for p in $(expand_pins "$(trim "$spec")"); do
      one_line "$p" "$u: tofu checksum" || continue
      is_sha256 "$v" || complain "$u: tofu checksum $p is '$v', not a sha256"
    done
  done <<< "$TOFU"
  while IFS='|' read -r u urow _ k _; do
    u=$(trim "$u"); [ -n "$u" ] || continue
    urow=$(trim "$urow")
    printf '%s\n' "$TOFU" | awk -F'|' -v u="$u" -v r="$urow" '{ x = $1; y = $3; gsub(/[[:space:]]/, "", x); gsub(/[[:space:]]/, "", y); if (x == u && y == r) f = 1 } END { exit !f }' \
      || complain "SIGS row for $u names $urow, which is no TOFU row of it"
    [ -f "$script_dir/keys/$(trim "$k")" ] || complain "SIGS row for $u: scripts/keys/$(trim "$k") does not exist"
  done <<< "$SIGS"
  [ "$bad" -eq 0 ] || { log error "$bad problem(s) in the tables"; return 1; }
  log info "tables consistent with $root"
}
if [ "$check" -eq 1 ]; then
  check_tables
  exit $?
fi

# --- which units, to which versions ------------------------------------------
# Kept in files, one per unit, rather than associative arrays (bash 3.2).
order=()
want_of() { cat "$tmp/want.$1"; }
add_want() {
  local unit="$1" v="$2"
  if [ ! -f "$tmp/want.$unit" ]; then
    order+=("$unit"); printf '%s' "$v" > "$tmp/want.$unit"; printf '%s' "${3:-}" > "$tmp/from.$unit"
  elif ver_gt "$v" "$(want_of "$unit")"; then
    printf '%s' "$v" > "$tmp/want.$unit"
  fi
}

if [ -n "$drift_file" ]; then
  [ -f "$drift_file" ] || { echo "error: $drift_file not found" >&2; exit 2; }
  jq -e '.tools | type == "array"' "$drift_file" >/dev/null 2>&1 \
    || { echo "error: $drift_file is not a check-pins.sh --format json report" >&2; exit 2; }
  while IFS=$'\t' read -r tool pinned latest; do
    unit=$(unit_for_tool "$tool")
    if [ -z "$unit" ]; then
      # A tool check-pins learned about and this script did not. Loud, so the
      # two tables cannot drift apart quietly.
      old="" new="$latest" edited_files=() integrity_urls=() pin_values=() version_url="" released=""
      fail_unit "$tool" "check-pins reports $tool behind, but bump-pins has no unit for it"
      continue
    fi
    add_want "$unit" "$latest" "$pinned"
  done < <(jq -r '.tools[] | select(.state == "behind") | [.tool, .pinned, .latest] | @tsv' "$drift_file")
else
  unit_field "$unit_arg" 1 >/dev/null || { echo "error: unknown unit '$unit_arg'" >&2; exit 2; }
  if [ -z "$to_arg" ]; then
    first_tool=$(unit_field "$unit_arg" 2 | cut -d, -f1)
    rc=0
    report=$("$script_dir/check-pins.sh" --only "$first_tool" --format json --quiet) || rc=$?
    to_arg=$(printf '%s' "$report" | jq -r '.tools[0].latest // empty' 2>/dev/null || true)
    [ -n "$to_arg" ] || { echo "error: could not resolve the latest $first_tool (check-pins exit $rc)" >&2; exit 1; }
  fi
  add_want "$unit_arg" "$to_arg"
fi

if [ "$plan" -eq 1 ]; then
  for unit in ${order[@]+"${order[@]}"}; do
    jq -nc --arg unit "$unit" --arg to "$(want_of "$unit")" --arg from "$(cat "$tmp/from.$unit")" \
      '{unit:$unit, from:$from, to:$to}'
  done
  cat "$results"   # tools with no unit, as error rows
  [ "$errors" -eq 0 ] || exit 1
  exit 0
fi

for unit in ${order[@]+"${order[@]}"}; do
  bump_unit "$unit" "$(want_of "$unit")"
done

if [ "$format" = json ]; then
  jq -s . "$results"
else
  printf '%-12s %-10s %-12s %-12s %-7s %s\n' UNIT STATUS OLD NEW CLASS DETAIL
  jq -r '[.unit, .status, (.old // "-"), (.new // "-"), (.class // "-"), (.error // .reason)] | @tsv' "$results" \
    | while IFS=$'\t' read -r u s o n c d; do printf '%-12s %-10s %-12s %-12s %-7s %s\n' "$u" "$s" "$o" "$n" "$c" "$d"; done
fi

[ "$errors" -eq 0 ] || { log error "$errors unit(s) failed"; exit 1; }
exit 0
