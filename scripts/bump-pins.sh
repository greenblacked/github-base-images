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
# kubectl (ci-tools + ci-cloud), Composer (ci-php84 + ci-php85), gitleaks
# (ci-security + security.yml), npm and Playwright (ci-node22 + ci-node24).
#
# Where the checksums come from is the point of this script. Every checksum it
# writes is read from the vendor's own published checksums file or registry
# record for that exact version -- never computed from a download. A hash of
# something we fetched attests only to what we happened to fetch; if that fetch
# were tampered with we would pin the tampered digest and every later check
# would pass. The build's `sha256sum --check` is then the cross-verification:
# if the vendor's file and the vendor's artifact ever disagree, CI goes red.
#
# Each bump is classified:
#   auto    the vendor publishes a checksum (or the registry an integrity
#           digest), the version change is not a semver major, and the release
#           is at least the cooldown old. Safe to merge once CI is green.
#   review  anything else that can still be bumped: no vendor checksum (AWS
#           CLI, Docker client, gcloud), a major version, or a release date the
#           script could not establish. The PR is opened, and a human merges it.
# and a release younger than the cooldown (BUMP_COOLDOWN_DAYS, default 7, the
# same seven days Dependabot waits) is not bumped at all this run: "deferred".
#
# Units are independent. Each is resolved in full, its edits staged on copies,
# and the real files written only once every edit for that unit succeeded; a
# failure in one unit is reported and never touches another unit's files.
#
# Offline testing: BUMP_PINS_FIXTURES=<dir> answers every HTTP request from
# <dir>/urls (lines of "<url> <file>", or "<url> @404"), and fails on any URL
# not listed there rather than falling through to the network. BUMP_PINS_NOW
# (epoch seconds) fixes "now" for the cooldown. See scripts/test-bump-pins.sh.
#
# Exit codes:
#   0  every unit was bumped, already current, or deferred
#   1  at least one unit failed (the others were still processed)
#   2  bad usage
set -euo pipefail

readonly TIMEOUT=25
readonly RETRIES=2

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
log_level=info

usage() {
  cat <<'EOF'
usage: bump-pins.sh (--drift FILE | --unit NAME [--to VERSION]) [options]

  --drift FILE   a `check-pins.sh --format json` report; bump every row that is behind
  --unit NAME    bump one unit (see UNITS below) to --to, or to the vendor's latest
  --to VERSION   the version to bump --unit to
  --plan         with --drift: print one JSON line per unit to bump, and edit nothing
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
    --quiet)  log_level=quiet; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$format" in table|json) ;; *) echo "error: --format must be table or json" >&2; exit 2 ;; esac
if [ -n "$drift_file" ] && [ -n "$unit_arg" ]; then
  echo "error: --drift and --unit are mutually exclusive" >&2; exit 2
fi
if [ -z "$drift_file" ] && [ -z "$unit_arg" ]; then
  echo "error: one of --drift or --unit is required" >&2; usage >&2; exit 2
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
#             none           the vendor publishes no checksum; EXISTS rows below
#                            only confirm the version is really there
#             npm:<package>  the registry's integrity digest, which the
#                            npm client itself verifies on install
#             rubygems:<gem> the registry's sha256 for the .gem
# release date (for the cooldown):
#             github:<owner/repo>:<tag>, hashicorp:<product>, npm:<package>,
#             rubygems:<gem>, or none
#
# {v} is replaced by the target version everywhere.
readonly UNITS='
terraform   | terraform           | ci-tools/Dockerfile.ci:TERRAFORM_VERSION | sums | hashicorp:terraform | https://releases.hashicorp.com/terraform/{v}/
kubectl     | kubectl             | ci-tools/Dockerfile.ci:KUBECTL_VERSION ci-cloud/Dockerfile.ci:KUBECTL_VERSION | sums | github:kubernetes/kubernetes:v{v} | https://github.com/kubernetes/kubernetes/releases/tag/v{v}
awscli      | awscli              | ci-tools/Dockerfile.ci:AWSCLI_VERSION | none | none | https://github.com/aws/aws-cli/blob/{v}/CHANGELOG.rst
docker      | docker              | ci-tools/Dockerfile.ci:DOCKER_VERSION | none | none | https://docs.docker.com/engine/release-notes/
gcloud      | gcloud              | ci-cloud/Dockerfile.ci:GCLOUD_VERSION | none | none | https://cloud.google.com/sdk/docs/release-notes
playwright  | playwright          | ci-node22/Dockerfile.ci:PLAYWRIGHT_VERSION ci-node24/Dockerfile.ci:PLAYWRIGHT_VERSION | npm:playwright | npm:playwright | https://www.npmjs.com/package/playwright/v/{v}
npm         | npm                 | ci-node22/Dockerfile.ci:NPM_VERSION ci-node24/Dockerfile.ci:NPM_VERSION | npm:npm | npm:npm | https://www.npmjs.com/package/npm/v/{v}
composer    | composer            | ci-php84/Dockerfile.ci:COMPOSER_VERSION ci-php85/Dockerfile.ci:COMPOSER_VERSION | sums | github:composer/composer:{v} | https://github.com/composer/composer/releases/tag/{v}
trivy       | trivy               | ci-security/Dockerfile.ci:TRIVY_VERSION | sums | github:aquasecurity/trivy:v{v} | https://github.com/aquasecurity/trivy/releases/tag/v{v}
syft        | syft                | ci-security/Dockerfile.ci:SYFT_VERSION | sums | github:anchore/syft:v{v} | https://github.com/anchore/syft/releases/tag/v{v}
grype       | grype               | ci-security/Dockerfile.ci:GRYPE_VERSION | sums | github:anchore/grype:v{v} | https://github.com/anchore/grype/releases/tag/v{v}
cosign      | cosign              | ci-security/Dockerfile.ci:COSIGN_VERSION | sums | github:sigstore/cosign:v{v} | https://github.com/sigstore/cosign/releases/tag/v{v}
gitleaks    | gitleaks,gitleaks-workflow | ci-security/Dockerfile.ci:GITLEAKS_VERSION .github/workflows/security.yml:GITLEAKS_VERSION | sums | github:gitleaks/gitleaks:v{v} | https://github.com/gitleaks/gitleaks/releases/tag/v{v}
migrate     | migrate             | ci-db/Dockerfile.ci:MIGRATE_VERSION | sums | github:golang-migrate/migrate:v{v} | https://github.com/golang-migrate/migrate/releases/tag/v{v}
osv-scanner | osv-scanner         | .github/workflows/build-image.yml:OSV_SCANNER_VERSION | sums | github:google/osv-scanner:v{v} | https://github.com/google/osv-scanner/releases/tag/v{v}
json        | json                | ci-ruby40/Dockerfile.ci:JSON_VERSION | rubygems:json | rubygems:json | https://rubygems.org/gems/json/versions/{v}
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
composer    | ci-php84/Dockerfile.ci:COMPOSER_SHA256        | https://getcomposer.org/download/{v}/composer.phar.sha256sum | composer.phar
composer    | ci-php85/Dockerfile.ci:COMPOSER_SHA256        | https://getcomposer.org/download/{v}/composer.phar.sha256sum | composer.phar
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

# unit | a URL that must exist at the target version. For the tools with no
# vendor checksum, so that a version the resolver misread is caught here rather
# than as a 404 halfway through a multi-arch build. Both architectures, since
# each is its own download.
readonly EXISTS='
awscli | https://awscli.amazonaws.com/awscli-exe-linux-x86_64-{v}.zip
awscli | https://awscli.amazonaws.com/awscli-exe-linux-aarch64-{v}.zip
docker | https://download.docker.com/linux/static/stable/x86_64/docker-{v}.tgz
docker | https://download.docker.com/linux/static/stable/aarch64/docker-{v}.tgz
gcloud | https://storage.googleapis.com/cloud-sdk-release/google-cloud-cli-{v}-linux-x86_64.tar.gz
gcloud | https://storage.googleapis.com/cloud-sdk-release/google-cloud-cli-{v}-linux-arm.tar.gz
'

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
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

http_get() {
  local url="$1" f auth=()
  if [ -n "$fixtures" ]; then
    if ! f=$(fixture_for "$url"); then
      log error "no fixture for $url -- refusing to reach the network in fixture mode"
      return 1
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

http_exists() {
  local url="$1" f
  if [ -n "$fixtures" ]; then
    f=$(fixture_for "$url") || { log error "no fixture for $url -- refusing to reach the network in fixture mode"; return 1; }
    [ "$f" != "@404" ]
    return
  fi
  curl -fsSL --retry "$RETRIES" --retry-all-errors --max-time "$TIMEOUT" -o /dev/null -I "$url"
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
release_date() {
  local spec="$1" v="$2" kind rest repo tag
  kind=${spec%%:*}; rest=${spec#*:}
  case "$kind" in
    github)
      repo=${rest%%:*}; tag=$(subst "${rest#*:}" "$v")
      http_get "https://api.github.com/repos/$repo/releases/tags/$tag" | jq -r '.published_at // empty' ;;
    hashicorp)
      http_get "https://api.releases.hashicorp.com/v1/releases/$rest/$v" | jq -r '.timestamp_created // empty' ;;
    npm)
      get_cached "https://registry.npmjs.org/$rest" | jq -r --arg v "$v" '.time[$v] // empty' ;;
    rubygems)
      get_cached "https://rubygems.org/api/v1/versions/$rest.json" \
        | jq -r --arg v "$v" '[.[] | select(.number == $v and .platform == "ruby")][0].created_at // empty' ;;
    none) ;;
    *) return 1 ;;
  esac
}

iso_to_epoch() { jq -rn --arg d "$1" '$d | sub("\\.[0-9]+"; "") | fromdateiso8601'; }

is_version() { printf '%s' "$1" | grep -qxE '[0-9]+(\.[0-9]+)*'; }
# 0 when $1 sorts strictly after $2.
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# --- reading and writing a pin -----------------------------------------------
# The three spellings check-pins.sh reads: a Dockerfile `ARG KEY=v`, a shell
# `KEY=v` at the start of a line, and a workflow `env:` entry `    KEY: v`.
get_pin() {
  local file="$1" key="$2"
  grep -m1 -E "^(ARG )?${key}=|^[[:space:]]+${key}:[[:space:]]" "$file" 2>/dev/null \
    | sed -E "s/^ARG //;s/^${key}=//;s/^[[:space:]]+${key}:[[:space:]]*//;s/[[:space:]].*$//" || true
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
results="$tmp/results.jsonl"
: > "$results"
errors=0

emit() {
  # emit UNIT STATUS OLD NEW CLASS REASON ERROR
  local files_json urls_json
  files_json=$(printf '%s\n' "${edited_files[@]:-}" | sed '/^$/d' | sort -u | jq -R . | jq -sc .)
  urls_json=$(printf '%s\n' "${integrity_urls[@]:-}" | sed '/^$/d' | sort -u | jq -R . | jq -sc .)
  jq -nc --arg unit "$1" --arg status "$2" --arg old "$3" --arg new "$4" \
    --arg class "$5" --arg reason "$6" --arg error "$7" \
    --arg tools "$(unit_field "$1" 2 2>/dev/null || true)" \
    --arg version_url "${version_url:-}" --arg released "${released:-}" \
    --argjson files "$files_json" --argjson integrity_urls "$urls_json" \
    '{unit:$unit, tools:($tools | split(",") | map(select(length > 0))), status:$status,
      old:(if $old == "" then null else $old end), new:(if $new == "" then null else $new end),
      class:(if $class == "" then null else $class end), reason:$reason,
      error:(if $error == "" then null else $error end),
      released:(if $released == "" then null else $released end),
      version_url:(if $version_url == "" then null else $version_url end),
      integrity_urls:$integrity_urls, files:$files}' >> "$results"
}

fail_unit() {
  log error "$1: $2"
  errors=$((errors + 1))
  emit "$1" error "${old:-}" "${new:-}" "" "" "$2"
}

bump_unit() {
  local unit="$1" new="$2" pins integrity date_spec
  local old="" pin file key cur all_new=1 note=""
  edited_files=(); integrity_urls=(); version_url=""; released=""

  pins=$(unit_field "$unit" 3) || { old=""; fail_unit "$unit" "unknown unit"; return 0; }
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
  local date_known=0 epoch age
  if [ "$date_spec" != none ]; then
    released=$(release_date "$date_spec" "$new" || true)
    if [ -n "$released" ] && epoch=$(iso_to_epoch "$released" 2>/dev/null) && [ -n "$epoch" ]; then
      date_known=1
      age=$(( (now - epoch) / 86400 ))
      if [ "$age" -lt "$cooldown_days" ]; then
        log info "$unit: $new was released $released, $age day(s) ago; deferred until it is $cooldown_days days old"
        emit "$unit" deferred "$old" "$new" "" "released $released, ${age}d ago; cooldown is ${cooldown_days}d" ""
        return 0
      fi
    else
      released=""
      log info "$unit: could not establish the release date of $new"
    fi
  fi

  # --- integrity: collect every edit before making any.
  local edits=() row sfile skey surl sname sum
  for pin in $pins; do edits+=("$pin=$new"); done
  case "$integrity" in
    sums)
      while IFS='|' read -r row_unit row_pin row_url row_name; do
        [ "$(trim "$row_unit")" = "$unit" ] || continue
        row=$(trim "$row_pin"); sfile=${row%%:*}; skey=${row#*:}
        surl=$(subst "$(trim "$row_url")" "$new"); sname=$(subst "$(trim "$row_name")" "$new")
        if ! sum=$(sum_from "$surl" "$sname"); then
          fail_unit "$unit" "no vendor checksum for $sname at $surl"; return 0
        fi
        integrity_urls+=("$surl")
        edits+=("$sfile:$skey=$sum")
      done <<< "$SUMS"
      [ "${#integrity_urls[@]}" -gt 0 ] || { fail_unit "$unit" "integrity is 'sums' but no SUMS rows"; return 0; }
      ;;
    none)
      while IFS='|' read -r row_unit row_url; do
        [ "$(trim "$row_unit")" = "$unit" ] || continue
        surl=$(subst "$(trim "$row_url")" "$new")
        http_exists "$surl" || { fail_unit "$unit" "$surl does not exist; is $new a real release?"; return 0; }
      done <<< "$EXISTS"
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
    *) fail_unit "$unit" "unknown integrity kind '$integrity'"; return 0 ;;
  esac

  # --- classify
  local class=auto reason
  if [ "$integrity" = none ]; then
    class=review
    reason="the vendor publishes no checksum for this download, so nothing but a human vouches for the new version"
  elif [ "${old%%.*}" != "${new%%.*}" ]; then
    class=review
    reason="major version change (${old%%.*} -> ${new%%.*})"
  elif [ "$date_known" -eq 0 ]; then
    class=review
    reason="release date unknown, so the ${cooldown_days}-day cooldown could not be confirmed"
  else
    case "$integrity" in
      sums)  reason="checksums from the vendor's published checksum file" ;;
      npm:*) reason="npm registry sha512 integrity, verified by npm on install" ;;
      *)     reason="registry-published sha256" ;;
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
    if ! set_pin "$copy" "$key" "$value"; then
      fail_unit "$unit" "could not set $key in $file"; return 0
    fi
  done
  for file in "${staged[@]}"; do
    cat "$stage/$(printf '%s' "$file" | tr '/' '_')" > "$root/$file"
    edited_files+=("$file")
  done

  log info "$unit: $old -> $new ($class)"
  emit "$unit" bumped "$old" "$new" "$class" "$reason" ""
}

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
      old="" new="$latest" edited_files=() integrity_urls=() version_url="" released=""
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
