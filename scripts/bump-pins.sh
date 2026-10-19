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
#   ./scripts/bump-pins.sh --refresh-keys           # refresh scripts/keys from the vendors
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
# A checksums file read from the same release as the artifact proves only that
# the two were published together: whoever could replace one could replace
# both. So wherever the vendor signs that file, the signature is checked
# before a single checksum is read from it (the SIGS table below): HashiCorp's
# GPG signature on terraform's SHA256SUMS, against HashiCorp's key pinned by
# fingerprint, and the Sigstore bundles trivy, syft, grype and cosign attach
# to their checksums files, with `cosign verify-blob` pinned to the vendor's
# own release identity -- the workflow (or service account) and the OIDC
# issuer that signed it, so a bundle signed by anyone else, a stranger's
# workflow included, fails. Where the vendor signs the artifacts rather than
# the checksums file, every digest the unit would pin must verify on its own
# before it is written: osv-scanner's SLSA provenance, GitHub artifact
# attestations (hadolint, actionlint, Composer), and kubectl's per-binary
# Sigstore signature, each with `cosign` pinned to the vendor's identity and
# repository. A signature or attestation that is missing, bad, or by another
# identity fails the unit: it is an error row, nothing is edited, and nothing
# is merged.
#
# The Docker CLI is installed from Docker's signed apt repository, and its pin
# is the package's exact version string rather than a checksum (integrity
# "apt", the APT table below). Its version is read only from the vendor's
# signed index, and only along the chain apt itself checks at build time:
# InRelease's inline GPG signature verified against Docker's key, pinned by
# fingerprint, before a line of it is read; then each architecture's Packages
# file matched to the SHA-256 the signed InRelease lists for it before a
# version is read from that. A signature that does not verify, a Packages
# file that does not match, or an architecture the index does not carry, is
# an error row, and nothing is edited.
#
# The exception is the two vendors that publish no checksum at all: the AWS
# CLI and gcloud (integrity "tofu"). For those this
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
# Composer is downloaded and hashed too, but it is not trust on first use
# (integrity "attested"): the hash is pinned only once GitHub's artifact
# attestation for exactly that digest verifies as Composer's release
# workflow, and the phar's GPG signature as Composer's key. The digest pinned
# is then the one the vendor attested, rather than one read from a second
# server's checksum file.
#
# Each bump is classified:
#   auto    the vendor publishes a checksum (or the registry an integrity
#           digest, or a signed apt index) -- signed, and the signature
#           verified, wherever the vendor signs it -- the version change is
#           not a semver major, and the release is at least the cooldown old
#           by the vendor's release date. Safe to merge once CI is green.
#   review  anything else that can still be bumped: no vendor checksum (AWS
#           CLI, gcloud), a major version, or no vendor release date to
#           measure the cooldown from (the Docker CLI: its apt index carries
#           none, so its verified bump cannot be auto -- an auto PR merges
#           with no first-seen clock, and would get no cooldown at all). It
#           merges itself once CI is green, but only after its PR has carried
#           that exact version for the cooldown (the first-seen clock above).
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
# throwaway key; the Sigstore, SLSA, attestation and kubectl rows run
# whatever `cosign` is first on PATH, which the tests make a fake, and the
# attestations API is answered from the same fixtures. See
# scripts/test-bump-pins.sh.
#
# The GPG keys in scripts/keys are refreshed from each vendor's official copy
# (the KEYS table below) every time one is used, before anything is verified
# with it: a committed key file never learns of a renewal or a revocation on
# its own. The refreshed key must be exactly the pinned primary key; it is
# merged into the committed one, and a bump whose merged key has anything new
# writes it back to scripts/keys as one of its edits. `--refresh-keys` does
# the same for every key on its own, with no version bump, for
# scripts/pin-bump-prs.sh's "Refresh vendor signing keys" PR.
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
refresh_keys=0
log_level=info

usage() {
  cat <<'EOF'
usage: bump-pins.sh (--drift FILE | --unit NAME [--to VERSION] | --refresh-keys | --check) [options]

  --drift FILE   a `check-pins.sh --format json` report; bump every row that is behind
  --unit NAME    bump one unit (see UNITS below) to --to, or to the vendor's latest
  --to VERSION   the version to bump --unit to (an apt unit's is
                 <upstream>-<revision>, e.g. docker --to 29.9.1-1)
  --refresh-keys refresh every key in scripts/keys from its vendor's official URL
                 (the KEYS table), with no version bump: one `signing-keys` row
  --plan         with --drift or --refresh-keys: print one JSON line per unit to
                 bump (or for the keys, when one changed), and edit nothing
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
    --refresh-keys) refresh_keys=1; shift ;;
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
if [ "$refresh_keys" -eq 1 ] && { [ -n "$drift_file" ] || [ -n "$unit_arg" ] || [ "$check" -eq 1 ]; }; then
  echo "error: --refresh-keys takes no --drift, --unit or --check" >&2; exit 2
fi
if [ "$check" -eq 0 ] && [ "$refresh_keys" -eq 0 ] && [ -z "$drift_file" ] && [ -z "$unit_arg" ]; then
  echo "error: one of --drift, --unit, --refresh-keys or --check is required" >&2; usage >&2; exit 2
fi
if [ -n "$to_arg" ] && [ -z "$unit_arg" ]; then
  echo "error: --to needs --unit" >&2; exit 2
fi
if [ "$plan" -eq 1 ] && [ -z "$drift_file" ] && [ "$refresh_keys" -eq 0 ]; then
  echo "error: --plan needs --drift or --refresh-keys" >&2; exit 2
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
#             tofu           the vendor publishes no checksum: each DOWNLOADS
#                            row below is the sha256 of our own download of
#                            that artifact (and a SIGS row, where there is
#                            one, a vendor signature checked first)
#             apt            the pin is a package's exact version string, from
#                            an APT row below: read from the vendor's signed
#                            apt index (InRelease, verified by its gpg SIGS
#                            row, then Packages, verified by the hash in it).
#                            The unit's version is that string's upstream
#                            version and Debian revision, without the epoch
#                            or distro suffix (5:29.9.0-1~debian.12~bookworm
#                            is 29.9.0-1; --to 29.9.0-2 asks for exactly
#                            that revision), and every version pin of the
#                            unit must be an APT
#                            row, so the two cannot disagree
#             attested       each DOWNLOADS row is downloaded and hashed, and
#                            the hash pinned only once a digest SIGS row
#                            (ghattest) verifies exactly that digest as the
#                            vendor's; classified like sums, not like tofu
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
docker      | docker              | ci-tools/Dockerfile.ci:DOCKER_CLI_VERSION | apt | first-seen | https://docs.docker.com/engine/release-notes/
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
composer    | composer            | */Dockerfile.ci:COMPOSER_VERSION | attested | github:composer/composer:{v} | https://github.com/composer/composer/releases/tag/{v}
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
# Dockerfile downloads it. The artifact is downloaded and hashed: for the
# tools with no vendor checksum, trust on first use (see the header); for an
# `attested` unit, a hash pinned only once the vendor's attestation for that
# digest verifies. Both architectures, since each is its own download --
# which also catches a version the resolver misread, here rather than as a
# 404 halfway through a multi-arch build.
readonly DOWNLOADS="
awscli   | ci-tools/Dockerfile.ci:AWSCLI_SHA256_AMD64 | https://awscli.amazonaws.com/awscli-exe-linux-x86_64-{v}.zip
awscli   | ci-tools/Dockerfile.ci:AWSCLI_SHA256_ARM64 | https://awscli.amazonaws.com/awscli-exe-linux-aarch64-{v}.zip
gcloud   | ci-cloud/Dockerfile.ci:GCLOUD_SHA256_AMD64 | https://storage.googleapis.com/cloud-sdk-release/google-cloud-cli-{v}-linux-x86_64.tar.gz
gcloud   | ci-cloud/Dockerfile.ci:GCLOUD_SHA256_ARM64 | https://storage.googleapis.com/cloud-sdk-release/google-cloud-cli-{v}-linux-arm.tar.gz
composer | */Dockerfile.ci:COMPOSER_SHA256            | $GH/composer/composer/releases/download/{v}/composer.phar
"

# unit | file:KEY the version string is written to | repository | suite
#      | component | package | architectures
#
# For an `apt` unit: the exact version string of the package, as the
# Dockerfile installs it (`package=<string>`), from the repository's signed
# index for that suite -- the same `deb <repository> <suite> <component>` line
# the Dockerfile writes. Its InRelease (<repository>/dists/<suite>/InRelease)
# must have an inline gpg SIGS row; nothing in it is read until that verifies,
# and the suite it names must be this one. Then, for each architecture, the
# component's binary-<arch>/Packages file must hash to exactly the SHA-256 the
# signed InRelease lists for it, and only then is it read: the newest version
# string of the package whose unit version -- upstream version and Debian
# revision, 29.9.1-2 for 5:29.9.1-2~debian.12~bookworm -- is exactly the
# target version. Every
# architecture must have one, and the same one. Both architectures the images
# are built for are listed (--check enforces it).
readonly APT="
docker   | ci-tools/Dockerfile.ci:DOCKER_CLI_VERSION | https://download.docker.com/linux/debian | bookworm | stable | docker-ce-cli | amd64 arm64
"

# unit | the file: a DOWNLOADS artifact, a SUMS checksums URL or an APT
#      | InRelease | its signature | method | two method-specific values
#      | (digest methods) a binding
#
# File methods -- the file itself is signed, and checked before the
# artifact's hash is recorded, or before any checksum is read from it:
#      | gpg       | key file in scripts/keys | primary key fingerprint
# A gpg row whose signature is `-` is an inline (clearsigned) signature: an
# apt InRelease, and only that (--check enforces it). The file must be
# exactly one clearsigned message, and what is read from it afterwards is
# what gpgv wrote out as signed -- never the file's own text, where lines
# outside the signed block could sit.
#      | sigstore  | certificate identity     | OIDC issuer
# Digest methods -- the vendor signs the artifacts, so each digest the unit
# would pin from that file (or hashed from that download) is checked on its
# own, and none is written until every one verifies:
#      | slsa      | builder identity | OIDC issuer | owner/repo@ref
#      | ghattest  | signer identity  | OIDC issuer | owner/repo
#      | sigcert   | signer identity  | OIDC issuer
# For slsa the signature column is the provenance bundle; for ghattest the
# repository's attestations API (`<api>/sha256:<digest>`); for sigcert the
# signed binary itself, whose `.sig` and `.cert` sit beside it.
#
# A unit with any row here must have one for every DOWNLOADS or SUMS URL it
# reads (--check enforces it): a vendor that signs signs everything we take
# from it, and an unsigned file beside signed ones is not taken on trust.
#
# gpg: `gpgv` must report a valid signature by exactly this key, made while
# the key (or the subkey that signed) was unexpired and unrevoked: EXPKEYSIG,
# EXPSIG and REVKEYSIG all fail the unit, as apt fails them at build time.
# The key is the committed key file merged with the vendor's current copy
# (the KEYS table below), so a key the vendor has renewed reads as renewed;
# one that has lapsed with no renewal anywhere fails closed. The key file must
# carry the pinned fingerprint, so swapping the file alone changes nothing; a
# new vendor key fails the bump, for a human to check and pin.
#   aws-cli.asc    AWS's published "AWS CLI Team" key, the fingerprint AWS
#                  documents for it. AWS extends its expiry from time to time
#                  and republishes it on its install guide (KEYS below).
#   hashicorp.asc  https://www.hashicorp.com/.well-known/pgp-key.txt, the
#                  fingerprint on https://www.hashicorp.com/security. It signs
#                  with a subkey; gpgv's VALIDSIG names the primary too.
#   composer.asc   "Packagist Conductors", the key that signs each release's
#                  composer.phar.asc; fetched from keyserver.ubuntu.com by
#                  its fingerprint and checked against 2.10.3's signature.
#                  Composer publishes no official copy of it (KEYS below).
#   docker.asc     "Docker Release (CE deb)", the key that signs Docker's apt
#                  repositories: https://download.docker.com/linux/debian/gpg,
#                  the fingerprint Docker's install documentation gives, and
#                  the one ci-tools/Dockerfile.ci pins as
#                  DOCKER_KEY_FINGERPRINT; checked against bookworm's
#                  InRelease. It signs with a subkey (D3306A01...F273FCD8);
#                  gpgv's VALIDSIG names the primary too.
#
# sigstore: `cosign verify-blob --bundle` against the public-good Sigstore
# instance (Fulcio certificate, Rekor inclusion), with the certificate's
# identity and issuer pinned exactly -- not a regexp. {v} in an identity is
# the target version, so trivy's bundle must come from that tag's release run.
# Each identity was read from a real release's certificate and verified with
# cosign before it was pinned here. The vendors' own release pipelines:
#   trivy    reusable-release.yaml, run for the tag (GitHub Actions OIDC)
#   syft,    release.yaml, which anchore runs from main for every release
#   grype    (so the ref is refs/heads/main, not the tag)
#   cosign   Google Cloud Build's keyless@projectsigstore service account, the
#            identity cosign's README documents for its releases. The cosign
#            that checks it is the one the pin-bump workflow installs
#            (sigstore/cosign-installer, pinned by SHA), never the release
#            being bumped: nothing this script verifies is ever executed.
#
# slsa: `cosign verify-blob-attestation --type slsaprovenance --digest`, for
# each pinned digest, against the release's in-toto bundle (a Sigstore
# bundle holding DSSE SLSA v0.2 provenance whose subjects are the release
# binaries). The identity is the SLSA generator's reusable workflow, which
# every user of that generator shares, so the source repository, the ref
# (the release's own tag) and the push trigger are pinned too -- without
# them any repository's provenance would pass. The generator version is in
# the identity: a release built by another one fails, for a person to check.
#   osv-scanner  slsa-github-generator generator_generic_slsa3.yml v2.1.0,
#                for google/osv-scanner at refs/tags/v{v}
#
# ghattest: GitHub artifact attestations. For each pinned digest, every
# attestation the repository's API lists for it (`GET <api>/sha256:<d>`,
# with GITHUB_TOKEN when it is set; public repositories need none) is tried
# with `cosign verify-blob-attestation --type slsaprovenance1 --digest`, the
# identity, issuer and repository pinned; the digest is accepted when one
# verifies. An API error, an empty list, or no bundle that verifies fails
# the unit. A bundle not inline is fetched from its bundle_url (which GitHub
# serves snappy-compressed; decoded here with python3).
#   hadolint    release.yml on refs/heads/master -- hadolint releases from
#               master, so the ref cannot be the tag
#   actionlint  release.yaml at refs/tags/v{v}
#   composer    release.yml at refs/tags/{v} (Composer's tags have no `v`);
#               the attested digest is of the phar on the GitHub release,
#               hashed from our download, and its .asc must also verify
#
# sigcert: kubectl signs each binary, not its .sha256, as a detached `.sig`
# and a short-lived Fulcio `.cert` (base64-wrapped PEM; decoded here) with
# no bundle. Each binary is downloaded, `cosign verify-blob --signature
# --certificate` checks it under the pinned identity and issuer (cosign
# finds its Rekor entry online, as the certificate expired ten minutes after
# signing), and its sha256 must then equal the one the unit would pin.
#   kubectl     krel-staging@k8s-releng-prod.iam.gserviceaccount.com, issuer
#               https://accounts.google.com
#
# Not here, and why (docs/security.md has the full list): gitleaks and
# golang-migrate publish no signature asset and no GitHub attestation;
# gcloud's tarball has only GCS md5/crc metadata. Those stay checksum-only
# (gitleaks, golang-migrate) or trust on first use (gcloud). The Docker CLI
# was trust on first use too, while it came from the unsigned static
# tarball; it now comes from Docker's signed apt repository, whose InRelease
# is the inline gpg row below.
readonly SIGS="
awscli    | https://awscli.amazonaws.com/awscli-exe-linux-x86_64-{v}.zip  | https://awscli.amazonaws.com/awscli-exe-linux-x86_64-{v}.zip.sig  | gpg | aws-cli.asc | FB5DB77FD5C118B80511ADA8A6310ACC4672475C
awscli    | https://awscli.amazonaws.com/awscli-exe-linux-aarch64-{v}.zip | https://awscli.amazonaws.com/awscli-exe-linux-aarch64-{v}.zip.sig | gpg | aws-cli.asc | FB5DB77FD5C118B80511ADA8A6310ACC4672475C
terraform | https://releases.hashicorp.com/terraform/{v}/terraform_{v}_SHA256SUMS | https://releases.hashicorp.com/terraform/{v}/terraform_{v}_SHA256SUMS.sig | gpg | hashicorp.asc | C874011F0AB405110D02105534365D9472D7468F
trivy     | $GH/aquasecurity/trivy/releases/download/v{v}/trivy_{v}_checksums.txt | $GH/aquasecurity/trivy/releases/download/v{v}/trivy_{v}_checksums.txt.sigstore.json | sigstore | $GH/aquasecurity/trivy/.github/workflows/reusable-release.yaml@refs/tags/v{v} | https://token.actions.githubusercontent.com
syft      | $GH/anchore/syft/releases/download/v{v}/syft_{v}_checksums.txt | $GH/anchore/syft/releases/download/v{v}/syft_{v}_checksums.txt.sigstore.json | sigstore | $GH/anchore/syft/.github/workflows/release.yaml@refs/heads/main | https://token.actions.githubusercontent.com
grype     | $GH/anchore/grype/releases/download/v{v}/grype_{v}_checksums.txt | $GH/anchore/grype/releases/download/v{v}/grype_{v}_checksums.txt.sigstore.json | sigstore | $GH/anchore/grype/.github/workflows/release.yaml@refs/heads/main | https://token.actions.githubusercontent.com
cosign    | $GH/sigstore/cosign/releases/download/v{v}/cosign_checksums.txt | $GH/sigstore/cosign/releases/download/v{v}/cosign_checksums.txt.sigstore.json | sigstore | keyless@projectsigstore.iam.gserviceaccount.com | https://accounts.google.com
osv-scanner | $GH/google/osv-scanner/releases/download/v{v}/osv-scanner_SHA256SUMS | $GH/google/osv-scanner/releases/download/v{v}/multiple.intoto.jsonl | slsa | $GH/slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@refs/tags/v2.1.0 | https://token.actions.githubusercontent.com | google/osv-scanner@refs/tags/v{v}
hadolint  | $GH/hadolint/hadolint/releases/download/v{v}/checksums.sha256 | https://api.github.com/repos/hadolint/hadolint/attestations | ghattest | $GH/hadolint/hadolint/.github/workflows/release.yml@refs/heads/master | https://token.actions.githubusercontent.com | hadolint/hadolint
actionlint | $GH/rhysd/actionlint/releases/download/v{v}/actionlint_{v}_checksums.txt | https://api.github.com/repos/rhysd/actionlint/attestations | ghattest | $GH/rhysd/actionlint/.github/workflows/release.yaml@refs/tags/v{v} | https://token.actions.githubusercontent.com | rhysd/actionlint
composer  | $GH/composer/composer/releases/download/{v}/composer.phar | $GH/composer/composer/releases/download/{v}/composer.phar.asc | gpg | composer.asc | 161DFBE342889F01DDAC4E61CBB3D576F2A0946F
docker    | https://download.docker.com/linux/debian/dists/bookworm/InRelease | - | gpg | docker.asc | 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
composer  | $GH/composer/composer/releases/download/{v}/composer.phar | https://api.github.com/repos/composer/composer/attestations | ghattest | $GH/composer/composer/.github/workflows/release.yml@refs/tags/{v} | https://token.actions.githubusercontent.com | composer/composer
kubectl   | https://dl.k8s.io/release/v{v}/bin/linux/amd64/kubectl.sha256 | https://dl.k8s.io/release/v{v}/bin/linux/amd64/kubectl | sigcert | krel-staging@k8s-releng-prod.iam.gserviceaccount.com | https://accounts.google.com
kubectl   | https://dl.k8s.io/release/v{v}/bin/linux/arm64/kubectl.sha256 | https://dl.k8s.io/release/v{v}/bin/linux/arm64/kubectl | sigcert | krel-staging@k8s-releng-prod.iam.gserviceaccount.com | https://accounts.google.com
"

# key file in scripts/keys | primary key fingerprint | the vendor's official
#   URL for that key ("-": the vendor publishes none) | how the key is served
#
# Every gpg SIGS row's key, and every file in scripts/keys, has a row here
# (--check enforces it, and that each URL is https). Whenever a key is used,
# its URL is fetched first (with http_get, like everything else) and:
#   - the fetched copy must hold exactly one primary key, exactly this
#     fingerprint, and no secret key; anything else fails the unit, and
#     nothing is written;
#   - it is merged into the committed key in a throwaway GNUPGHOME. gpg checks
#     every self-signature it imports, so only what this key itself signed
#     can be added -- a renewed expiry, a new subkey, a revocation -- and
#     nothing is ever taken away. Signatures are verified against the merged
#     key;
#   - a revocation the merge adds, or any revocation of the primary key, fails
#     the unit: that is for a human, never a bump;
#   - when the merge added anything, a unit that bumps also writes the merged
#     key, armored, to scripts/keys as one of its edits, so its PR carries the
#     refreshed key for review (--refresh-keys does it on its own);
#   - when the fetch fails, the committed key is used as it is, with a
#     warning. A key that has expired there then fails the unit (above).
# How the key is served:
#   armor  the response is the armored key
#   html   a web page: tags stripped, entities decoded, and exactly one
#          distinct BEGIN/END PGP PUBLIC KEY BLOCK taken from it; none, an
#          unterminated one, or two different ones, fail
# The sources:
#   aws-cli.asc    the AWS CLI install guide, whose Linux section carries the
#                  key in a code block (docs.aws.amazon.com)
#   hashicorp.asc  https://www.hashicorp.com/.well-known/pgp-key.txt
#   docker.asc     https://download.docker.com/linux/debian/gpg, which
#                  ci-tools/Dockerfile.ci also installs (by fingerprint)
#   composer.asc   none: Composer's download page links each phar's .asc but
#                  no key, and composer.github.io/pubkeys.html is the OpenSSL
#                  keys for `composer self-update`, not this GPG key. Used as
#                  committed; refreshed by hand from a keyserver
readonly KEYS="
aws-cli.asc   | FB5DB77FD5C118B80511ADA8A6310ACC4672475C | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html | html
hashicorp.asc | C874011F0AB405110D02105534365D9472D7468F | https://www.hashicorp.com/.well-known/pgp-key.txt | armor
docker.asc    | 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 | https://download.docker.com/linux/debian/gpg | armor
composer.asc  | 161DFBE342889F01DDAC4E61CBB3D576F2A0946F | - | -
"

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

# verify_sig UNIT URL FILE -- the file methods: 0 when no gpg or sigstore
# SIGS row covers URL, or when its signature verifies under the pinned key or
# identity; 1, with the reason logged, when not. The digest methods are
# verify_digest's, once the digests are known.
verify_sig() {
  local unit="$1" url="$2" file="$3" row_unit row_url row_sig row_method row_a row_b
  while IFS='|' read -r row_unit row_url row_sig row_method row_a row_b _; do
    [ "$(trim "$row_unit")" = "$unit" ] || continue
    [ "$(subst "$(trim "$row_url")" "$new")" = "$url" ] || continue
    case "$(trim "$row_method")" in
      gpg)      verify_gpg "$unit" "$url" "$file" "$(subst "$(trim "$row_sig")" "$new")" "$(trim "$row_a")" "$(trim "$row_b")" || return 1 ;;
      sigstore) verify_sigstore "$unit" "$url" "$file" "$(subst "$(trim "$row_sig")" "$new")" \
                  "$(subst "$(trim "$row_a")" "$new")" "$(trim "$row_b")" || return 1 ;;
      slsa|ghattest|sigcert) ;;
      *) log error "SIGS row for $unit: unknown method '$(trim "$row_method")'"; return 1 ;;
    esac
  done <<< "$SIGS"
  return 0
}

# verify_digest UNIT URL SHA256 -- the digest methods, for one digest the unit
# would pin from URL (a SUMS checksums file, or a DOWNLOADS artifact it
# hashed): 0 when every slsa, ghattest or sigcert row covering URL verifies
# it; 3 when no such row covers URL; 1, with the reason logged, when one does
# not. A verdict is kept for the run, per unit, URL and digest: kubectl's
# two images read the same two files, and its binaries are 60 MB each.
verify_digest() {
  local unit="$1" url="$2" sum="$3" row_unit row_url row_sig row_method row_a row_b row_c n=0 marker sig a b c
  # The key must be injective: a short checksum of the digest would let a
  # crafted digest collide with one already verified and skip its check. The
  # digest goes in verbatim (hex only), the unit and URL as their sha256.
  case "$sum" in
    ''|*[!0-9a-f]*) log error "$unit: '$sum' is not a hex digest"; return 1 ;;
  esac
  printf '%s %s' "$unit" "$url" > "$tmp/digest.key"
  marker="$tmp/digest.$(sha256_of "$tmp/digest.key").$sum"
  [ -f "$marker" ] && return 0
  while IFS='|' read -r row_unit row_url row_sig row_method row_a row_b row_c; do
    [ "$(trim "$row_unit")" = "$unit" ] || continue
    [ "$(subst "$(trim "$row_url")" "$new")" = "$url" ] || continue
    sig=$(subst "$(trim "$row_sig")" "$new"); a=$(subst "$(trim "$row_a")" "$new")
    b=$(trim "$row_b"); c=$(subst "$(trim "$row_c")" "$new")
    case "$(trim "$row_method")" in
      gpg|sigstore) continue ;;
      slsa)     verify_slsa "$unit" "$sum" "$sig" "$a" "$b" "$c" || return 1 ;;
      ghattest) verify_ghattest "$unit" "$sum" "$sig" "$a" "$b" "$c" || return 1 ;;
      sigcert)  verify_sigcert "$unit" "$sum" "$sig" "$a" "$b" || return 1 ;;
      *) log error "SIGS row for $unit: unknown method '$(trim "$row_method")'"; return 1 ;;
    esac
    n=$((n + 1))
  done <<< "$SIGS"
  [ "$n" -gt 0 ] || return 3
  : > "$marker"
}

# Each verifier adds the way it verified, once, for the PR's reason line.
add_note() {
  case "|$(printf '%s|' "${signed_notes[@]:-}")" in *"|$1|"*) ;; *) signed_notes+=("$1") ;; esac
}

# verify_slsa UNIT SHA256 BUNDLE_URL IDENTITY ISSUER REPO@REF -- SHA256 is a
# subject of the SLSA provenance in the bundle at BUNDLE_URL, signed as
# exactly IDENTITY and ISSUER for a push to REF of REPO.
verify_slsa() {
  local unit="$1" sum="$2" sig_url="$3" identity="$4" issuer="$5" binding="$6" repo ref f
  repo=${binding%%@*}; ref=${binding#*@}
  if [ -z "$repo" ] || [ "$repo" = "$binding" ] || [ -z "$ref" ]; then
    log error "SIGS row for $unit: '$binding' is not owner/repo@ref"; return 1
  fi
  command -v cosign >/dev/null || { log error "cosign is needed to verify $sig_url"; return 1; }
  f=$(cache_file "$sig_url") || { log error "no provenance at $sig_url"; return 1; }
  if ! cosign verify-blob-attestation --bundle "$f" --type slsaprovenance \
         --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
         --certificate-github-workflow-repository "$repo" --certificate-github-workflow-ref "$ref" \
         --certificate-github-workflow-trigger push \
         --digest "$sum" --digestAlg sha256 < /dev/null > "$tmp/cosign.out" 2>&1; then
    log error "$sig_url does not attest sha256:$sum as $identity for $repo at $ref: $(tail -1 "$tmp/cosign.out")"
    return 1
  fi
  integrity_urls+=("$sig_url")
  add_note "every pinned digest verified as a subject of the vendor's SLSA provenance (pinned builder, repository and tag)"
  log info "$unit: sha256:$sum is attested by $sig_url"
}

# Snappy block decompression, for an attestation bundle fetched from its
# bundle_url (GitHub stores them compressed). Reads stdin, writes stdout,
# exits 1 on anything that is not a well-formed block.
readonly SNAPPY_PY='
import sys
d = sys.stdin.buffer.read(); i = 0; n = 0; s = 0
while True:
    if i >= len(d) or s > 35: sys.exit(1)
    c = d[i]; i += 1; n |= (c & 0x7f) << s; s += 7
    if c < 0x80: break
if n > 64 << 20: sys.exit(1)
out = bytearray()
while i < len(d):
    t = d[i]; i += 1; k = t & 3
    if k == 0:
        l = t >> 2
        if l >= 60:
            w = l - 59; l = int.from_bytes(d[i:i + w], "little"); i += w
        l += 1
        if i + l > len(d): sys.exit(1)
        out += d[i:i + l]; i += l
    else:
        if k == 1:
            l = ((t >> 2) & 7) + 4; o = ((t >> 5) << 8) | d[i]; i += 1
        elif k == 2:
            l = (t >> 2) + 1; o = int.from_bytes(d[i:i + 2], "little"); i += 2
        else:
            l = (t >> 2) + 1; o = int.from_bytes(d[i:i + 4], "little"); i += 4
        if o == 0 or o > len(out): sys.exit(1)
        for _ in range(l): out.append(out[-o])
    if len(out) > n: sys.exit(1)
if len(out) != n: sys.exit(1)
sys.stdout.buffer.write(out)
'

# fetch_bundle URL DEST -- an attestation bundle from its bundle_url: plain
# JSON, or snappy-compressed JSON. 1 when it is neither.
fetch_bundle() {
  local url="$1" dest="$2"
  case "$url" in https://*) ;; *) log error "bundle_url '$url' is not https"; return 1 ;; esac
  rm -f "$dest.raw"
  http_download "$url" "$dest.raw" || { log error "could not fetch $url"; return 1; }
  if jq -e 'type == "object"' "$dest.raw" >/dev/null 2>&1; then
    mv "$dest.raw" "$dest"; return 0
  fi
  command -v python3 >/dev/null || { log error "python3 is needed to decompress $url"; return 1; }
  if ! python3 -I -c "$SNAPPY_PY" < "$dest.raw" > "$dest" 2>/dev/null \
     || ! jq -e 'type == "object"' "$dest" >/dev/null 2>&1; then
    log error "$url is not a bundle, plain or snappy-compressed"; rm -f "$dest"; return 1
  fi
  rm -f "$dest.raw"
}

# verify_ghattest UNIT SHA256 API IDENTITY ISSUER REPO -- one of the GitHub
# artifact attestations listed for SHA256 at API verifies as SLSA v1
# provenance for that digest, signed as exactly IDENTITY and ISSUER from REPO.
verify_ghattest() {
  local unit="$1" sum="$2" api="$3" identity="$4" issuer="$5" repo="$6" url body n i b burl rc=0 ok=0
  url="$api/sha256:$sum?per_page=100"
  command -v cosign >/dev/null || { log error "cosign is needed to verify $url"; return 1; }
  body=$(http_get "$url") || rc=$?
  if [ "$rc" -ne 0 ]; then
    log error "$unit: no GitHub attestation listed for sha256:$sum at $url (exit $rc)"; return 1
  fi
  n=$(jq -r 'if (.attestations | type) == "array" then .attestations | length else "none" end' <<<"$body" 2>/dev/null) || n=""
  case "$n" in
    ''|*[!0-9]*) log error "$unit: $url is not an attestations list"; return 1 ;;
    0) log error "$unit: $url lists no attestation for sha256:$sum"; return 1 ;;
  esac
  : > "$tmp/cosign.out"
  i=0
  while [ "$i" -lt "$n" ]; do
    b="$tmp/attestation.$i.json"; rm -f "$b"
    if jq -e --argjson i "$i" '.attestations[$i].bundle | type == "object"' <<<"$body" >/dev/null 2>&1; then
      jq -c --argjson i "$i" '.attestations[$i].bundle' <<<"$body" > "$b"
    else
      burl=$(jq -r --argjson i "$i" '.attestations[$i].bundle_url // empty | strings' <<<"$body")
      if [ -z "$burl" ] || ! fetch_bundle "$burl" "$b"; then
        log info "$unit: attestation $i for sha256:$sum has no bundle that could be read"
        rm -f "$b"
      fi
    fi
    if [ -s "$b" ] && cosign verify-blob-attestation --bundle "$b" --type slsaprovenance1 \
         --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
         --certificate-github-workflow-repository "$repo" \
         --digest "$sum" --digestAlg sha256 < /dev/null > "$tmp/cosign.out" 2>&1; then
      ok=1; break
    fi
    i=$((i + 1))
  done
  if [ "$ok" -ne 1 ]; then
    log error "$unit: none of the $n attestation(s) at $url verifies sha256:$sum as $identity from $repo: $(tail -1 "$tmp/cosign.out")"
    return 1
  fi
  integrity_urls+=("$api")
  add_note "every pinned digest verified against the vendor's GitHub artifact attestation (pinned workflow identity and repository)"
  log info "$unit: sha256:$sum is attested by $identity"
}

# verify_sigcert UNIT SHA256 BLOB_URL IDENTITY ISSUER -- the binary at
# BLOB_URL carries a valid Sigstore signature (BLOB_URL.sig, certificate
# BLOB_URL.cert) by exactly IDENTITY and ISSUER, and hashes to SHA256.
verify_sigcert() {
  local unit="$1" sum="$2" blob_url="$3" identity="$4" issuer="$5" bin="$tmp/signed.blob" got
  command -v cosign >/dev/null || { log error "cosign is needed to verify $blob_url"; return 1; }
  rm -f "$bin" "$bin.sig" "$bin.cert" "$bin.pem"
  http_download "$blob_url" "$bin" || { log error "could not download $blob_url"; return 1; }
  http_download "$blob_url.sig" "$bin.sig" || { log error "no signature at $blob_url.sig"; rm -f "$bin"; return 1; }
  http_download "$blob_url.cert" "$bin.cert" || { log error "no certificate at $blob_url.cert"; rm -f "$bin"; return 1; }
  # The vendor serves the PEM base64-wrapped. cosign v3 would unwrap it
  # itself; it is unwrapped here so that what is checked does not depend on
  # that fallback, and anything else is refused.
  if head -1 "$bin.cert" | grep -qx -- '-----BEGIN CERTIFICATE-----'; then
    cp "$bin.cert" "$bin.pem"
  elif ! tr -d '\r\n' < "$bin.cert" | base64 -d > "$bin.pem" 2>/dev/null \
       || ! head -1 "$bin.pem" | grep -qx -- '-----BEGIN CERTIFICATE-----'; then
    log error "$blob_url.cert is not a PEM certificate, plain or base64-wrapped"; rm -f "$bin"; return 1
  fi
  if ! cosign verify-blob --signature "$bin.sig" --certificate "$bin.pem" \
         --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
         "$bin" < /dev/null > "$tmp/cosign.out" 2>&1; then
    log error "$blob_url.sig does not verify $blob_url as $identity ($issuer): $(tail -1 "$tmp/cosign.out")"
    rm -f "$bin"; return 1
  fi
  got=$(sha256_of "$bin"); rm -f "$bin"
  if [ "$got" != "$sum" ]; then
    log error "$blob_url verifies as $identity, but its sha256 is $got, not the $sum the unit would pin"
    return 1
  fi
  integrity_urls+=("$blob_url.sig" "$blob_url.cert")
  add_note "each binary's Sigstore signature verified under the vendor's pinned identity, and its sha256 matched"
  log info "$unit: $blob_url verifies as $identity, sha256 $sum"
}

# verify_sigstore UNIT URL FILE BUNDLE_URL IDENTITY ISSUER -- the vendor's
# Sigstore bundle for FILE verifies, and its certificate names exactly
# IDENTITY and ISSUER. cosign checks the Fulcio chain, the Rekor inclusion
# proof and the signature; the pinned identity is what makes it the vendor's
# signature rather than anyone's.
verify_sigstore() {
  local unit="$1" url="$2" file="$3" sig_url="$4" identity="$5" issuer="$6"
  command -v cosign >/dev/null || { log error "cosign is needed to verify $sig_url"; return 1; }
  rm -f "$tmp/artifact.sigstore.json"
  http_download "$sig_url" "$tmp/artifact.sigstore.json" || { log error "no signature at $sig_url"; return 1; }
  if ! cosign verify-blob --bundle "$tmp/artifact.sigstore.json" \
         --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
         "$file" > "$tmp/cosign.out" 2>&1; then
    log error "$sig_url does not verify $url as $identity ($issuer): $(tail -1 "$tmp/cosign.out")"
    return 1
  fi
  integrity_urls+=("$sig_url")
  add_note "its Sigstore signature verified under the vendor's pinned release identity"
  log info "$unit: $url verifies as $identity"
}

# key_field KEYFILE N -- column N (1-based) of the key's KEYS row.
key_field() {
  local line
  line=$(printf '%s\n' "$KEYS" | awk -F'|' -v k="$1" '{ x=$1; gsub(/[[:space:]]/, "", x); if (x == k) { print; exit } }')
  [ -n "$line" ] || return 1
  trim "$(printf '%s' "$line" | cut -d'|' -f"$2")"
}

# key_source KEYFILE FPR -- where the committed key is read from, and the
# fingerprint it must be: scripts/keys and FPR, or in fixture mode
# BUMP_PINS_KEYS and BUMP_PINS_KEY_FPR when set. Sets key_path, key_fpr.
key_source() {
  local keydir="$script_dir/keys"
  key_fpr="$2"
  if [ -n "$fixtures" ]; then
    keydir=${BUMP_PINS_KEYS:-$keydir}; key_fpr=${BUMP_PINS_KEY_FPR:-$key_fpr}
  fi
  key_path="$keydir/$1"
}

# primaries_of FILE -- the fingerprint of every primary key in FILE, one per
# line, and "secret" for each secret key in it, which no key file may hold.
# A private GNUPGHOME: nothing is read from, or left in, the runner's own.
primaries_of() {
  mkdir -p "$tmp/gnupg"; chmod 700 "$tmp/gnupg"
  GNUPGHOME="$tmp/gnupg" gpg --batch --show-keys --with-colons "$1" 2>/dev/null \
    | awk -F: '$1 == "sec" { print "secret" } $1 == "pub" || $1 == "sec" { p = 1; next } p && $1 == "fpr" { print $10; p = 0 }'
}

# The armored key on a vendor's web page: the page with every tag stripped
# (a <br> is a line break) and its entities decoded, once -- the named ones
# below, and numeric ones that are printable ASCII; anything else is left as
# it is, for gpg to refuse. Of what is left, the lines from
# `-----BEGIN PGP PUBLIC KEY BLOCK-----` to `-----END PGP PUBLIC KEY BLOCK-----`,
# each trimmed of the page's indentation. Exactly one distinct block, or exit
# 2 (none), 3 (one never ended, or one inside another) or 4 (two that
# differ). The same block twice, as a page with tabs may repeat it, is one.
# shellcheck disable=SC2016  # awk's own $0, not this shell's
readonly HTML_KEY_AWK='
BEGIN { MB = "-----BEGIN PGP PUBLIC KEY BLOCK-----"; ME = "-----END PGP PUBLIC KEY BLOCK-----" }
function hexval(h,   i, n) {
  n = 0; h = tolower(h)
  for (i = 1; i <= length(h); i++) n = n * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
  return n
}
{ doc = doc $0 "\n" }
END {
  gsub(/\r/, "", doc)
  gsub(/<[bB][rR][^>]*>/, "\n", doc)
  gsub(/<[^>]*>/, "", doc)
  out = ""
  while (match(doc, /&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);/)) {
    ent = substr(doc, RSTART + 1, RLENGTH - 2); rep = "&" ent ";"; n = -1
    if (ent == "amp") rep = "&"
    else if (ent == "lt") rep = "<"
    else if (ent == "gt") rep = ">"
    else if (ent == "quot") rep = "\""
    else if (ent == "apos") rep = "\047"
    else if (ent == "nbsp") rep = " "
    else if (ent ~ /^#[xX]/) n = hexval(substr(ent, 3))
    else if (ent ~ /^#/) n = substr(ent, 2) + 0
    if (n == 10 || (n >= 32 && n < 127)) rep = sprintf("%c", n)
    out = out substr(doc, 1, RSTART - 1) rep
    doc = substr(doc, RSTART + RLENGTH)
  }
  doc = out doc
  nl = split(doc, line, "\n"); inb = 0; blocks = 0
  for (i = 1; i <= nl; i++) {
    l = line[i]; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l)
    # The markers may share a line with the text of the page once tags are
    # stripped ("Paste this:-----BEGIN ..."), so they are found anywhere in it.
    if ((k = index(l, MB)) > 0) {
      if (inb) exit 3
      inb = 1; cur = ""; l = substr(l, k)
    }
    if (!inb) continue
    if ((k = index(l, ME)) > 0) l = substr(l, 1, k + length(ME) - 1)
    cur = cur l "\n"
    if (k > 0 && l ~ /-----END PGP PUBLIC KEY BLOCK-----$/) {
      inb = 0
      if (!(cur in seen)) { seen[cur] = 1; blocks++; first = cur }
    }
  }
  if (inb) exit 3
  if (blocks == 0) exit 2
  if (blocks > 1) exit 4
  printf "%s", first
}'
html_key_block() { awk "$HTML_KEY_AWK" "$1"; }

# key_fail DIR MESSAGE -- a key refresh failed: logged, and remembered for
# the rest of the run, so every row that uses the key fails the same way.
key_err=""
key_fail() { key_err=$2; printf '%s' "$2" > "$1/failed"; log error "$2"; return 1; }

# revocations FPR HOME -- how many of FPR's keys (primary and subkeys) are
# revoked in HOME's keyring.
revocations() {
  GNUPGHOME="$2" gpg --batch --with-colons --list-keys "$1" 2>/dev/null \
    | awk -F: '($1 == "pub" || $1 == "sub") && $2 == "r" { n++ } END { print n + 0 }'
}

# refresh_key KEYFILE NAME FPR -- the keyring to verify NAME's signatures
# against: KEYFILE (the committed key, already checked to be exactly FPR)
# merged with the vendor's current copy from its KEYS row (see the table).
# Sets key_ring (a binary keyring for gpgv), key_base (the committed key
# alone, exported the same way), key_changed (1 when the merge added
# anything), key_asc (the merged key, armored, when it did) and key_src (the
# URL the vendor's copy came from; empty when there is none or it could not
# be fetched). 1, with the reason logged, when the vendor's copy is not
# exactly FPR, or the merged key is revoked. Once per key per run; later
# calls reuse the outcome.
refresh_key() {
  local keyfile="$1" name="$2" fpr="$3" d="$tmp/key.$2" url fmt rc=0 got revs
  key_ring="$d/ring.gpg"; key_base="$d/base.gpg"; key_asc="$d/merged.asc"; key_changed=0; key_src=""
  if [ -f "$d/failed" ]; then key_err=$(cat "$d/failed"); log error "$key_err"; return 1; fi
  if [ -f "$d/done" ]; then
    key_changed=$(cat "$d/changed"); key_src=$(cat "$d/src"); return 0
  fi
  rm -rf "$d"; mkdir -p "$d/home"; chmod 700 "$d/home"
  if ! url=$(key_field "$name" 3); then
    key_fail "$d" "$name has no KEYS row, so it cannot be refreshed"; return 1
  fi
  fmt=$(key_field "$name" 4)
  # self-sigs-only, import-clean: gpg checks a key's own signatures on import
  # but keeps third-party certifications unchecked, so a copy padded with
  # them (certificate flooding) would otherwise grow the merged key and be
  # written back. Only what the vendor's own key signed is kept.
  if ! GNUPGHOME="$d/home" gpg --batch --quiet --import-options self-sigs-only,import-clean --import "$keyfile" > /dev/null 2>&1; then
    key_fail "$d" "could not import $keyfile"; return 1
  fi
  GNUPGHOME="$d/home" gpg --batch --export "$fpr" > "$key_base" 2>/dev/null || true
  [ -s "$key_base" ] || { key_fail "$d" "could not export $fpr from $keyfile"; return 1; }
  revs=$(revocations "$fpr" "$d/home")
  if [ "$url" != - ]; then
    rc=0; http_get "$url" > "$d/fetched.raw" || rc=$?
    if [ "$rc" -eq "$NO_FIXTURE" ]; then
      key_fail "$d" "$name: no fixture for its refresh URL $url"; return 1
    elif [ "$rc" -ne 0 ]; then
      log warn "$name: could not fetch the vendor's current key from $url (exit $rc); verifying against the committed copy, which may be stale"
    elif [ "$(wc -c < "$d/fetched.raw")" -gt 2097152 ]; then
      # The real pages and keys are a few hundred KB at most.
      key_fail "$d" "$name: $url is over 2 MB, not a key or a page carrying one"; return 1
    else
      case "$fmt" in
        armor) cp "$d/fetched.raw" "$d/fetched.asc" ;;
        html)
          rc=0; html_key_block "$d/fetched.raw" > "$d/fetched.asc" || rc=$?
          case "$rc" in
            0) ;;
            2) key_fail "$d" "$name: $url has no PGP PUBLIC KEY BLOCK"; return 1 ;;
            4) key_fail "$d" "$name: $url has more than one different PGP PUBLIC KEY BLOCK"; return 1 ;;
            *) key_fail "$d" "$name: $url has a PGP PUBLIC KEY BLOCK that is not well formed"; return 1 ;;
          esac ;;
        *) key_fail "$d" "KEYS row for $name: unknown format '$fmt'"; return 1 ;;
      esac
      got=$(primaries_of "$d/fetched.asc" | paste -sd' ' -)
      if [ "$got" != "$fpr" ]; then
        key_fail "$d" "$name: the key at $url is not exactly the key $fpr (it holds: ${got:-no key})"; return 1
      fi
      if ! GNUPGHOME="$d/home" gpg --batch --quiet --import-options self-sigs-only,import-clean --import "$d/fetched.asc" > /dev/null 2>&1; then
        key_fail "$d" "$name: could not import the key at $url"; return 1
      fi
      key_src=$url
    fi
  fi
  # Both copies were exactly the one key, so the keyring must be too.
  got=$(GNUPGHOME="$d/home" gpg --batch --with-colons --list-keys 2>/dev/null \
    | awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print $10; p = 0 }' | paste -sd' ' -)
  [ "$got" = "$fpr" ] || { key_fail "$d" "$name: the merged keyring is not exactly the key $fpr ($got)"; return 1; }
  if GNUPGHOME="$d/home" gpg --batch --with-colons --list-keys "$fpr" 2>/dev/null \
       | awk -F: '$1 == "pub" && $2 == "r" { r = 1 } END { exit !r }'; then
    local where="in the committed key"
    if [ -n "$key_src" ]; then where="in the committed key or the vendor's copy at $key_src"; fi
    key_fail "$d" "$name: the key $fpr is revoked ($where); a revoked key verifies nothing, and a person has to look"
    return 1
  fi
  if [ "$(revocations "$fpr" "$d/home")" != "$revs" ]; then
    key_fail "$d" "$name: the vendor's copy at $key_src revokes a subkey of $fpr that the committed key does not; a person has to look before anything is verified with it"
    return 1
  fi
  GNUPGHOME="$d/home" gpg --batch --export "$fpr" > "$key_ring" 2>/dev/null || true
  [ -s "$key_ring" ] || { key_fail "$d" "$name: could not export the merged key"; return 1; }
  if ! cmp -s "$key_base" "$key_ring"; then
    key_changed=1
    GNUPGHOME="$d/home" gpg --batch --armor --export "$fpr" > "$key_asc" 2>/dev/null || true
    [ -s "$key_asc" ] || { key_fail "$d" "$name: could not export the merged key"; return 1; }
    log info "$name: the vendor's copy at $key_src adds to the committed key (a renewal, new signatures or subkeys)"
  fi
  printf '%s' "$key_changed" > "$d/changed"; printf '%s' "$key_src" > "$d/src"; : > "$d/done"
}

# verify_gpg UNIT URL FILE SIG_URL KEYFILE FPR -- SIG_URL is a valid detached
# signature on FILE by exactly the key FPR, read from scripts/keys/KEYFILE
# and refreshed from its vendor (refresh_key) first. SIG_URL `-`: FILE is
# itself one clearsigned message by that key, and what it signs is written to
# FILE.signed, the only copy of it a caller may read.
verify_gpg() {
  local unit="$1" url="$2" file="$3" sig_url="$4" row_key="$5" fpr="$6"
  local keyfile status cmd
  key_source "$row_key" "$fpr"
  keyfile=$key_path; fpr=$key_fpr
  for cmd in gpg gpgv; do
    command -v "$cmd" >/dev/null || { log error "$cmd is needed to verify $sig_url"; return 1; }
  done
  [ -f "$keyfile" ] || { log error "signing key $keyfile is missing"; return 1; }
  if [ "$(primaries_of "$keyfile")" != "$fpr" ]; then
    log error "$keyfile is not exactly the key $fpr"
    return 1
  fi
  refresh_key "$keyfile" "$row_key" "$fpr" || return 1
  if [ "$sig_url" = - ]; then
    # Inline: one clearsigned message and nothing else. gpgv verifies only the
    # signed block, so text before it, or a second message after it, would be
    # read by a parser that took the file as it is; refused instead, and the
    # caller reads gpgv's own output of what was signed.
    rm -f "$file.signed" "$file.signed.part"
    if [ "$(head -1 "$file" 2>/dev/null)" != '-----BEGIN PGP SIGNED MESSAGE-----' ] \
       || [ "$(grep -c -- '^-----BEGIN PGP SIGNED MESSAGE-----' "$file" 2>/dev/null)" != 1 ]; then
      log error "$url is not exactly one clearsigned message"
      return 1
    fi
    sig_url=$url
    status=$(GNUPGHOME="$tmp/gnupg" gpgv --status-fd 1 --keyring "$key_ring" --output "$file.signed.part" "$file" 2>/dev/null) \
      || { rm -f "$file.signed.part"; log error "$url does not verify under $fpr"; return 1; }
  else
    rm -f "$tmp/artifact.sig"
    http_download "$sig_url" "$tmp/artifact.sig" || { log error "no signature at $sig_url"; return 1; }
    status=$(GNUPGHOME="$tmp/gnupg" gpgv --status-fd 1 --keyring "$key_ring" "$tmp/artifact.sig" "$file" 2>/dev/null) \
      || { log error "$sig_url does not verify $url under $fpr"; return 1; }
  fi
  if printf '%s\n' "$status" | grep -qE '^\[GNUPG:\] (REVKEYSIG|BADSIG|ERRSIG)'; then
    rm -f "$file.signed.part"
    log error "$sig_url: the key is revoked, or the signature is bad"
    return 1
  fi
  # A signature by an expired key or subkey, or an expired signature, is
  # refused for every row, inline or detached: apt refuses one on an
  # InRelease at build time, and a detached one is held to the same rule.
  # The key was refreshed from its vendor above, so a key the vendor renewed
  # does not read as expired here; one still expired after that (no renewal
  # published, or the vendor unreachable) fails closed.
  if printf '%s\n' "$status" | grep -qE '^\[GNUPG:\] (EXPKEYSIG|EXPSIG)'; then
    rm -f "$file.signed.part"
    log error "$sig_url: signed by an expired key, or the signature has expired${key_src:+ (even after refreshing the key from $key_src)}"
    return 1
  fi
  if ! printf '%s\n' "$status" | awk -v f="$fpr" '$2 == "VALIDSIG" && ($3 == f || $NF == f) { ok = 1 } END { exit !ok }'; then
    rm -f "$file.signed.part"
    log error "$sig_url is not a valid signature by $fpr"
    return 1
  fi
  if [ -f "$file.signed.part" ]; then mv "$file.signed.part" "$file.signed"; fi
  integrity_urls+=("$sig_url")
  add_note "its GPG signature verified under the vendor's pinned key"
  if [ -n "$key_src" ]; then integrity_urls+=("$key_src"); fi
  if [ "$key_changed" = 1 ]; then
    case " ${key_edits[*]:-} " in *" $row_key "*) ;; *) key_edits+=("$row_key") ;; esac
  fi
  log info "$unit: $url verifies under $fpr"
}

# Cached per URL: several SUMS rows read the same checksums file. cache_file
# fetches it once and prints where it is; get_cached prints its content. The
# signature on a checksums file is checked on that same cached copy, so the
# bytes verified are the bytes every checksum is then read from.
cache_file() {
  local url="$1" key
  # sha256, not a short checksum: two URLs must never share a cached file.
  printf '%s' "$url" > "$tmp/cache.key"
  key=$(sha256_of "$tmp/cache.key")
  if [ ! -f "$tmp/cache.$key" ]; then
    local rc=0
    http_get "$url" > "$tmp/cache.$key.part" || rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$tmp/cache.$key.part"; return "$rc"; }
    mv "$tmp/cache.$key.part" "$tmp/cache.$key"
  fi
  printf '%s' "$tmp/cache.$key"
}
get_cached() {
  local f rc=0
  f=$(cache_file "$1") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  cat "$f"
}

# verify_sums UNIT URL -- the checksums file at URL is fetched, and its SIGS
# row (if any) verified, once per run; later rows reading the same file reuse
# the verdict. 0 verified or unsigned, 1 a signature that does not verify, 2
# the file itself could not be fetched (left for sum_from to report).
verify_sums() {
  local unit="$1" url="$2" f marker
  f=$(cache_file "$url") || return 2
  marker="$f.verified.$unit"
  [ -f "$marker" ] && return 0
  verify_sig "$unit" "$url" "$f" || return 1
  : > "$marker"
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

# apt_resolve UNIT VERSION REPOSITORY SUITE COMPONENT PACKAGE ARCHES -- the
# version string of PACKAGE whose unit version (apt_unit_version: upstream
# version and Debian revision, 29.9.1-2) is exactly VERSION, from the signed
# index of SUITE (the APT table's comment has the chain), in apt_value; on any
# broken link sets apt_err to the reason and returns 1. Not run in a command
# substitution: the URLs and notes it records belong to this unit.
apt_err="" apt_value=""
apt_resolve() {
  local unit="$1" v="$2" repo="$3" suite="$4" comp="$5" pkg="$6" arches="$7"
  local rel_url f signed arch path want pkgs_url pf got found cand one="" rc
  apt_err=""; apt_value=""
  rel_url="$repo/dists/$suite/InRelease"
  rc=0; f=$(cache_file "$rel_url") || rc=$?
  [ "$rc" -eq 0 ] || { apt_err="could not fetch $rel_url (exit $rc)"; return 1; }
  # The signature first. verify_sig passes a file no row covers, so the
  # signed copy only gpg's inline method writes is what proves a row did.
  rm -f "$f.signed"
  verify_sig "$unit" "$rel_url" "$f" || { apt_err="the vendor signature on $rel_url does not verify${key_err:+ ($key_err)}"; return 1; }
  [ -s "$f.signed" ] || { apt_err="$rel_url has no inline gpg SIGS row, so nothing in it is read"; return 1; }
  signed="$f.signed"
  # A validly signed InRelease of another suite is still Docker's; it must
  # not stand in for this one.
  if ! awk -v s="$suite" '($1 == "Suite:" || $1 == "Codename:") && $2 == s { ok = 1 } END { exit !ok }' "$signed"; then
    apt_err="the signed $rel_url does not name the suite $suite"; return 1
  fi
  for arch in $arches; do
    path="$comp/binary-$arch/Packages"
    # Exactly one SHA256 line for the file, in the signed SHA256 section.
    want=$(awk -v p="$path" '
      /^[^ \t]/ { sec = $1; next }
      sec == "SHA256:" && $3 == p { print $1; n++ }
      END { exit n != 1 }' "$signed") || want=""
    if ! is_sha256 "$want"; then
      apt_err="the signed $rel_url lists no single SHA-256 for $path: $suite does not carry $arch"; return 1
    fi
    pkgs_url="$repo/dists/$suite/$path"
    rc=0; pf=$(cache_file "$pkgs_url") || rc=$?
    [ "$rc" -eq 0 ] || { apt_err="could not fetch $pkgs_url (exit $rc)"; return 1; }
    got=$(sha256_of "$pf")
    if [ "$got" != "$want" ]; then
      apt_err="$pkgs_url hashes to $got, not the $want the signed InRelease lists for it"; return 1
    fi
    # Only now is it read: the one version string of PACKAGE for ARCH whose
    # unit version is exactly VERSION. Two (the same upstream version and
    # revision under two distro suffixes) are ambiguous, and refused.
    found=""
    while IFS= read -r cand; do
      [ "$(apt_unit_version "$cand" || true)" = "$v" ] || continue
      if [ -n "$found" ] && [ "$cand" != "$found" ]; then
        apt_err="$pkgs_url has two $pkg version strings for $v on $arch, $found and $cand"; return 1
      fi
      found=$cand
    done < <(awk -v pkg="$pkg" -v a="$arch" '
      function done_stanza() {
        if (p == pkg && ar == a && ver != "") print ver
        p = ""; ar = ""; ver = ""
      }
      { sub(/\r$/, "") }
      /^$/ { done_stanza(); next }
      /^Package: / { p = $2 } /^Architecture: / { ar = $2 } /^Version: / { ver = $2 }
      END { done_stanza() }' "$pf")
    if [ -z "$found" ]; then
      apt_err="$pkgs_url has no $pkg $v for $arch"; return 1
    fi
    if [ -n "$one" ] && [ "$found" != "$one" ]; then
      apt_err="the architectures disagree: $pkg $v is $one for one and $found for $arch"; return 1
    fi
    one=$found
    integrity_urls+=("$pkgs_url")
  done
  [ -n "$one" ] || { apt_err="no architectures to read $pkg from"; return 1; }
  add_note "each Packages index matched the SHA-256 its signed InRelease lists"
  apt_value=$one
}

iso_to_epoch() { jq -rn --arg d "$1" '$d | sub("\\.[0-9]+"; "") | fromdateiso8601'; }

is_version() { printf '%s' "$1" | grep -qxE '[0-9]+(\.[0-9]+)*'; }
# A Debian version string, [epoch:]upstream-revision, with the revision
# required (every package in a vendor's repository has one), in the
# characters Debian allows -- nothing that could break out of an ARG line.
is_apt_version() { printf '%s' "$1" | grep -qxE '([0-9]+:)?[0-9][A-Za-z0-9.+~]*-[A-Za-z0-9.+~]+'; }
# Its unit version, the one check-pins reports and the drift and --to ask
# for: the upstream version and the Debian revision, without the epoch or the
# distro suffix after the revision's first `~` (5:29.9.0-1~debian.12~bookworm
# -> 29.9.0-1). The revision is part of it, so a fix Docker ships only as a
# new revision (29.9.0-2) is a bump like any release. Exactly <dotted
# upstream>-<dotted revision> (is_apt_unit_version), or nothing and a
# failure. The same helper is in scripts/check-pins.sh.
apt_unit_version() {
  local v="$1" up rev re_num='^[0-9]+(\.[0-9]+)*$'
  is_apt_version "$v" || return 1
  v=${v#*:}   # the epoch: the only place a Debian version string has a colon
  up=${v%-*}; rev=${v##*-}; rev=${rev%%~*}
  if ! [[ $up =~ $re_num ]] || ! [[ $rev =~ $re_num ]]; then return 1; fi
  printf '%s-%s\n' "$up" "$rev"
}
# An apt unit's version: 29.9.0-1, which sort -V (ver_gt) orders as dpkg
# does: 29.9.0-1 < 29.9.0-2 < 29.9.0-10 < 29.10.0-1.
is_apt_unit_version() { printf '%s' "$1" | grep -qxE '[0-9]+(\.[0-9]+)*-[0-9]+(\.[0-9]+)*'; }
# unit_version_ok INTEGRITY VERSION -- VERSION has the shape of that unit's
# versions: <upstream>-<revision> for an apt unit, a dotted number otherwise.
unit_version_ok() { if [ "$1" = apt ]; then is_apt_unit_version "$2"; else is_version "$2"; fi; }
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
edited_files=(); integrity_urls=(); pin_values=(); signed_notes=(); key_edits=(); emit_integrity=""
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
    --arg integrity "${emit_integrity:-$(unit_field "$1" 4 2>/dev/null || true)}" \
    --arg cooldown "$(if [ "$(unit_field "$1" 5 2>/dev/null || true)" = first-seen ]; then echo first-seen; else echo release-date; fi)" \
    --arg version_url "${version_url:-}" --arg released "${released:-}" \
    --argjson files "$files_json" --argjson integrity_urls "$urls_json" --argjson pins "$pins_json" \
    '{unit:$unit, tools:($tools | split(",") | map(select(length > 0))), status:$status,
      old:(if $old == "" then null else $old end), new:(if $new == "" then null else $new end),
      class:(if $class == "" then null else $class end), reason:$reason,
      error:(if $error == "" then null else $error end),
      integrity:(if $integrity == "" then null else ($integrity | sub(":.*"; "")) end),
      cooldown:(if $integrity == "" or $integrity == "keys" then null else $cooldown end),
      released:(if $released == "" then null else $released end),
      version_url:(if $version_url == "" then null else $version_url end),
      integrity_urls:$integrity_urls, files:$files, pins:$pins}' >> "$results"
}

fail_unit() {
  log error "$1: $2"
  errors=$((errors + 1))
  emit "$1" error "${old:-}" "${new:-}" "" "" "$2"
}

# write_key NAME -- scripts/keys/NAME in --root becomes the key refresh_key
# merged for it (armored), and is listed as an edited file.
write_key() {
  mkdir -p "$root/scripts/keys"
  cat "$tmp/key.$1/merged.asc" > "$root/scripts/keys/$1"
  edited_files+=("scripts/keys/$1")
}

bump_unit() {
  local unit="$1" new="$2" pins integrity date_spec
  local old="" pin file key cur all_new=1 note=""
  edited_files=(); integrity_urls=(); pin_values=(); signed_notes=(); key_edits=(); key_err=""; version_url=""; released=""

  pins=$(unit_field "$unit" 3) || { old=""; fail_unit "$unit" "unknown unit"; return 0; }
  # shellcheck disable=SC2086  # one spec per word
  pins=$(expand_pins $pins)
  [ -n "$pins" ] || { fail_unit "$unit" "no image in .github/images.json pins $(unit_field "$unit" 3)"; return 0; }
  integrity=$(unit_field "$unit" 4)
  date_spec=$(unit_field "$unit" 5)
  version_url=$(subst "$(unit_field "$unit" 6)" "$new")

  # An apt unit's version is <upstream>-<revision> (apt_unit_version); every
  # other unit's a dotted number.
  local version_shape="a dotted number"
  if [ "$integrity" = apt ]; then version_shape="<upstream>-<revision>, such as 29.9.0-1"; fi
  if ! unit_version_ok "$integrity" "$new"; then fail_unit "$unit" "target version '$new' is not $version_shape"; return 0; fi

  # Every copy of the pin is read. The first is the one check-pins reports.
  for pin in $pins; do
    file=${pin%%:*}; key=${pin#*:}
    [ -f "$root/$file" ] || { fail_unit "$unit" "$file does not exist"; return 0; }
    cur=$(get_pin "$root/$file" "$key")
    [ -n "$cur" ] || { fail_unit "$unit" "no $key in $file"; return 0; }
    # An apt pin is the package's whole version string; the unit's version,
    # the one check-pins reports and the drift asks for, is its upstream
    # version and Debian revision (apt_unit_version).
    if [ "$integrity" = apt ]; then
      is_apt_version "$cur" || { fail_unit "$unit" "$key in $file is '$cur', not a Debian version string"; return 0; }
      cur=$(apt_unit_version "$cur") \
        || { fail_unit "$unit" "$key in $file is '$(get_pin "$root/$file" "$key")', not <upstream>-<revision> once its epoch and distro suffix are cut"; return 0; }
    fi
    [ -n "$old" ] || old=$cur
    [ "$cur" = "$old" ] || note="copies disagreed before this bump ($file had $cur); all now move together. "
    [ "$cur" = "$new" ] || all_new=0
  done

  if [ "$all_new" -eq 1 ]; then
    log info "$unit: already at $new"
    emit "$unit" current "$old" "$new" "" "already at $new" ""
    return 0
  fi
  if ! unit_version_ok "$integrity" "$old"; then fail_unit "$unit" "pinned version '$old' is not $version_shape"; return 0; fi
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
  # An apt unit's version pins are its APT rows, written below with the
  # whole version string; every other unit's are the bare version.
  if [ "$integrity" != apt ]; then
    for pin in $pins; do edits+=("$pin=$new"); done
  fi
  case "$integrity" in
    apt)
      local row_repo row_suite row_comp row_pkg row_arches
      while IFS='|' read -r row_unit row_pin row_repo row_suite row_comp row_pkg row_arches; do
        [ "$(trim "$row_unit")" = "$unit" ] || continue
        if ! apt_resolve "$unit" "$new" "$(trim "$row_repo")" "$(trim "$row_suite")" "$(trim "$row_comp")" \
               "$(trim "$row_pkg")" "$(trim "$row_arches")"; then
          fail_unit "$unit" "$apt_err"; return 0
        fi
        if ! is_apt_version "$apt_value" || [ "$(apt_unit_version "$apt_value" || true)" != "$new" ]; then
          fail_unit "$unit" "the signed index gave '$apt_value' for $new"; return 0
        fi
        for row in $(expand_pins "$(trim "$row_pin")"); do
          edits+=("$row=$apt_value")
        done
      done <<< "$APT"
      # Every version pin must have been written from the index: one left
      # out would keep the old version while the unit reported the new one.
      for pin in $pins; do
        case " ${edits[*]:-} " in
          *" $pin="*) ;;
          *) fail_unit "$unit" "$pin is a version pin of an apt unit, but no APT row writes it"; return 0 ;;
        esac
      done
      ;;
    sums)
      while IFS='|' read -r row_unit row_pin row_url row_name; do
        [ "$(trim "$row_unit")" = "$unit" ] || continue
        surl=$(subst "$(trim "$row_url")" "$new"); sname=$(subst "$(trim "$row_name")" "$new")
        # The signature first: not one checksum is read from a file whose
        # vendor signs it until that signature verifies.
        rc=0; verify_sums "$unit" "$surl" || rc=$?
        if [ "$rc" -eq 1 ]; then
          fail_unit "$unit" "the vendor signature on $surl does not verify${key_err:+ ($key_err)}"; return 0
        fi
        if ! sum=$(sum_from "$surl" "$sname"); then
          fail_unit "$unit" "no vendor checksum for $sname at $surl"; return 0
        fi
        # And where the vendor signs the artifacts instead, this digest
        # itself: it is staged, never written, until that verifies.
        rc=0; verify_digest "$unit" "$surl" "$sum" || rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
          # A bare-hash file names nothing; its URL says what it is for.
          [ "$sname" != - ] || sname=$(basename "$(dirname "$surl")")/$(basename "$surl" .sha256)
          fail_unit "$unit" "the vendor attestation for $sname (sha256:$sum, from $surl) does not verify"; return 0
        fi
        integrity_urls+=("$surl")
        for row in $(expand_pins "$(trim "$row_pin")"); do
          sfile=${row%%:*}; skey=${row#*:}
          edits+=("$sfile:$skey=$sum")
        done
      done <<< "$SUMS"
      [ "${#integrity_urls[@]}" -gt 0 ] || { fail_unit "$unit" "integrity is 'sums' but no SUMS rows"; return 0; }
      ;;
    tofu|attested)
      # Download each artifact, check its vendor signature where there is
      # one, and hash what came. tofu records that hash on first use; an
      # attested unit records it only once the vendor's attestation for
      # exactly that digest verifies.
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
          rm -f "$dl"; fail_unit "$unit" "the vendor signature on $surl does not verify${key_err:+ ($key_err)}"; return 0
        fi
        sum=$(sha256_of "$dl"); rm -f "$dl"
        is_sha256 "$sum" || { fail_unit "$unit" "could not hash $surl"; return 0; }
        rc=0; verify_digest "$unit" "$surl" "$sum" || rc=$?
        if [ "$rc" -eq 3 ] && [ "$integrity" = attested ]; then
          fail_unit "$unit" "integrity is 'attested' but no attestation row covers $surl"; return 0
        fi
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
          fail_unit "$unit" "the vendor attestation for $surl (sha256:$sum) does not verify"; return 0
        fi
        integrity_urls+=("$surl")
        for row in $(expand_pins "$(trim "$row_pin")"); do
          sfile=${row%%:*}; skey=${row#*:}
          edits+=("$sfile:$skey=$sum")
        done
      done <<< "$DOWNLOADS"
      [ "${#integrity_urls[@]}" -gt 0 ] || { fail_unit "$unit" "integrity is '$integrity' but no DOWNLOADS rows"; return 0; }
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
  local class=auto reason signed="" n_note
  for n_note in "${signed_notes[@]:-}"; do
    [ -n "$n_note" ] || continue
    if [ -z "$signed" ]; then signed=$n_note; else signed="$signed; $n_note"; fi
  done
  if [ "$integrity" = tofu ]; then
    class=review
    reason="the vendor publishes no checksum: sha256 recorded from our own download (trust on first use"
    [ -z "$signed" ] || reason="$reason, after the vendor signature verified"
    reason="$reason); merges only once its PR has carried this version for ${cooldown_days} days (first-seen cooldown)"
  elif [ "${old%%.*}" != "${new%%.*}" ]; then
    class=review
    reason="major version change (${old%%.*} -> ${new%%.*}); ${released:+released $released; }merges only once its PR has carried this version for ${cooldown_days} days (first-seen cooldown)"
    if [ "$integrity" = attested ]; then
      reason="sha256 hashed from our download, pinned only after $signed; $reason"
    elif [ "$integrity" = apt ]; then
      reason="version string from the vendor's signed apt index, $signed; $reason"
    elif [ -n "$signed" ]; then
      reason="vendor checksum file, $signed; $reason"
    fi
  else
    case "$integrity" in
      sums)   reason="checksums from the vendor's published checksum file"
              [ -z "$signed" ] || reason="$reason, $signed" ;;
      attested) reason="sha256 of the vendor's release artifact, hashed from our download and pinned only after $signed" ;;
      apt)    reason="version string from the vendor's signed apt index, $signed; apt checks the same chain, and every .deb's hash, at build time" ;;
      npm:*)  reason="npm registry sha512 integrity, verified by npm on install" ;;
      pypi:*) reason="sha256 of every linux wheel from PyPI's JSON API, installed with pip --require-hashes" ;;
      *)      reason="registry-published sha256" ;;
    esac
    if [ "$date_spec" = first-seen ]; then
      # Verified like a signed checksum, but with no vendor release date the
      # cooldown has not been applied yet: an auto PR merges with no
      # first-seen clock, so this one must carry it (see the header).
      class=review
      reason="$reason; not a major version; the vendor publishes no release date, so it merges only once its PR has carried this version for ${cooldown_days} days (first-seen cooldown)"
    else
      reason="$reason; not a major version; released $released"
    fi
  fi
  reason="$note$reason"
  local kname
  for kname in "${key_edits[@]:-}"; do
    [ -n "$kname" ] || continue
    reason="$reason; the signing key was refreshed first from the vendor's copy at $(cat "$tmp/key.$kname/src"), which renews or adds to the committed one, so scripts/keys/$kname is updated here too"
  done

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
  # A signing key the vendor renewed or added to (verify_gpg): its merged
  # copy, so the PR carries it and later runs start from it.
  for kname in "${key_edits[@]:-}"; do
    [ -n "$kname" ] || continue
    if [ ! -s "$tmp/key.$kname/merged.asc" ]; then
      fail_unit "$unit" "the refreshed $kname is missing"; return 0
    fi
  done
  for file in "${staged[@]}"; do
    cat "$stage/$(printf '%s' "$file" | tr '/' '_')" > "$root/$file"
    edited_files+=("$file")
  done
  for kname in "${key_edits[@]:-}"; do
    [ -n "$kname" ] || continue
    write_key "$kname"
  done

  log info "$unit: $old -> $new ($class)"
  emit "$unit" bumped "$old" "$new" "$class" "$reason" ""
}

# --- --check: the tables against the tree ------------------------------------
# Every pin a unit names, every checksum row and every download row must be
# exactly one line in --root, holding a version or a sha256; every tofu or
# attested unit must have its download rows and every download row such a
# unit; every signature row must match a download or checksum row of its
# unit, name a key file that exists or an exact identity, a known issuer and
# (for the digest methods) the repository it binds; and every download an
# attested unit reads must have a digest row. Read-only and offline, so
# scripts/test-bump-pins.sh runs it over the real tree on every lint: a
# renamed ARG fails there, not in a bump that silently skipped a checksum.
check_tables() {
  local bad=0 line u p f k n v spec specs integ urow
  complain() { log error "$*"; bad=$((bad + 1)); }
  apt_pins_of() { # UNIT -- the pins its APT rows write, one per line
    local au ap
    while IFS='|' read -r au ap _; do
      [ "$(trim "$au")" = "$1" ] || continue
      expand_pins "$(trim "$ap")"
    done <<< "$APT"
  }
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
      if [ "$integ" = apt ]; then
        if ! is_apt_version "$v" || ! apt_unit_version "$v" > /dev/null; then
          complain "$u: pin $p is '$v', not a Debian version string of <upstream>-<revision>"
        fi
        apt_pins_of "$u" > "$tmp/apt.pins"
        grep -qxF "$p" "$tmp/apt.pins" || complain "$u: pin $p is a version pin of an apt unit, but no APT row writes it"
        continue
      fi
      is_version "$v" || complain "$u: pin $p is '$v', not a version"
      case "$p" in
        *.txt:*)
          case "$integ" in pypi:*) ;; *) complain "$u: $p is a requirements pin, but integrity is $integ" ;; esac
          awk -v k="${p#*:}" '$0 ~ ("^" k "==") { on = 1; next } on && /--hash=sha256:[0-9a-f]+/ { h++ } on && !/\\[[:space:]]*$/ { on = 0 } END { exit !h }' \
            "$root/${p%%:*}" || complain "$u: $p has no --hash=sha256 lines" ;;
      esac
    done
    case "$integ" in
      tofu|attested)
        printf '%s\n' "$DOWNLOADS" | awk -F'|' -v u="$u" '{ x = $1; gsub(/[[:space:]]/, "", x); if (x == u) f = 1 } END { exit !f }' \
          || complain "$u: integrity is $integ but there is no DOWNLOADS row" ;;
    esac
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
    case "$(unit_field "$u" 4 2>/dev/null || true)" in
      tofu|attested) ;;
      *) complain "DOWNLOADS row for $u, which is not a tofu or attested unit" ;;
    esac
    for p in $(expand_pins "$(trim "$spec")"); do
      one_line "$p" "$u: downloaded checksum" || continue
      is_sha256 "$v" || complain "$u: downloaded checksum $p is '$v', not a sha256"
    done
  done <<< "$DOWNLOADS"
  # An APT row: an apt unit's, writing a Debian version string, from an https
  # repository, for both architectures the images are built for. Each one's
  # InRelease is a URL the unit reads, and must be signed inline (below).
  local ar arepo asuite acomp apkg aarches apt_reads=""
  while IFS='|' read -r u spec arepo asuite acomp apkg aarches; do
    u=$(trim "$u"); [ -n "$u" ] || continue
    arepo=$(trim "$arepo"); asuite=$(trim "$asuite"); acomp=$(trim "$acomp"); apkg=$(trim "$apkg"); aarches=$(trim "$aarches")
    [ "$(unit_field "$u" 4 2>/dev/null || true)" = apt ] || complain "APT row for $u, which is not an apt unit"
    for p in $(expand_pins "$(trim "$spec")"); do
      one_line "$p" "$u: apt version" || continue
      is_apt_version "$v" || complain "$u: apt version $p is '$v', not a Debian version string"
    done
    printf '%s' "$arepo" | grep -qxE 'https://[A-Za-z0-9.-]+(/[A-Za-z0-9._-]+)*' || complain "APT row for $u: '$arepo' is not an https repository URL"
    for ar in "$asuite" "$acomp" "$apkg"; do
      printf '%s' "$ar" | grep -qxE '[a-z0-9][a-z0-9.+-]*' || complain "APT row for $u: '$ar' is not a suite, component or package name"
    done
    for ar in amd64 arm64; do
      case " $aarches " in *" $ar "*) ;; *) complain "APT row for $u does not read $ar" ;; esac
    done
    for ar in $aarches; do
      case "$ar" in amd64|arm64) ;; *) complain "APT row for $u: '$ar' is not an architecture the images are built for" ;; esac
    done
    apt_reads="$apt_reads $u|$arepo/dists/$asuite/InRelease"
  done <<< "$APT"
  # A URL a unit reads: column 3 of its DOWNLOADS rows, column 3 of its SUMS
  # rows, the InRelease of its APT rows.
  reads_url() { # UNIT URL
    case " $apt_reads " in *" $1|$2 "*) return 0 ;; esac
    printf '%s\n%s\n' "$DOWNLOADS" "$SUMS" | awk -F'|' -v u="$1" -v r="$2" '
      { x = $1; y = $3; gsub(/[[:space:]]/, "", x); gsub(/[[:space:]]/, "", y); if (x == u && y == r) f = 1 } END { exit !f }'
  }
  # An exact identity: a workflow URL at a ref, or a service account. cosign
  # compares it exactly, so a pattern character could only ever fail; it
  # still means the row was written as a regexp.
  exact_identity() { # UNIT IDENTITY
    printf '%s' "$2" | grep -qE '^https://github\.com/[^/]+/[^/]+/\.github/workflows/[^@]+@refs/(tags|heads)/[^[:space:]]+$|^[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$' \
      || complain "SIGS row for $1: '$2' is not an exact workflow or service-account identity"
    if printf '%s' "$2" | grep -qE '[][*?()|\\^$+]'; then
      complain "SIGS row for $1: '$2' contains a pattern character; identities are exact"
    fi
  }
  known_issuer() { # UNIT ISSUER [ONLY]
    case "$2" in
      https://token.actions.githubusercontent.com|https://accounts.google.com)
        [ -z "${3:-}" ] || [ "$2" = "$3" ] || complain "SIGS row for $1: '$2' is not the issuer this method takes ($3)" ;;
      *) complain "SIGS row for $1: '$2' is not a known OIDC issuer" ;;
    esac
  }
  local sm ss sa sb sc signed_units="" digest_rows="" inline_rows="" gpg_keys=""
  while IFS='|' read -r u urow ss sm sa sb sc; do
    u=$(trim "$u"); [ -n "$u" ] || continue
    urow=$(trim "$urow"); ss=$(trim "$ss"); sm=$(trim "$sm"); sa=$(trim "$sa"); sb=$(trim "$sb"); sc=$(trim "$sc")
    reads_url "$u" "$urow" || complain "SIGS row for $u names $urow, which is no DOWNLOADS or SUMS row of it"
    case " $signed_units " in *" $u "*) ;; *) signed_units="$signed_units $u" ;; esac
    case "$sm" in
      gpg|sigstore|sigcert)
        [ -z "$sc" ] || complain "SIGS row for $u: a $sm row takes no binding column ('$sc')" ;;
    esac
    case "$sm" in
      slsa|ghattest|sigcert)
        digest_rows="$digest_rows $u|$urow"
        case "$(unit_field "$u" 4 2>/dev/null || true)" in
          sums|attested) ;;
          *) complain "SIGS row for $u: a $sm row needs a sums or attested unit" ;;
        esac ;;
    esac
    case "$sm" in
      gpg)
        [ -f "$script_dir/keys/$sa" ] || complain "SIGS row for $u: scripts/keys/$sa does not exist"
        printf '%s' "$sb" | grep -qxE '[0-9A-F]{40}' || complain "SIGS row for $u: '$sb' is not a full key fingerprint"
        [ "$(key_field "$sa" 2 2>/dev/null || true)" = "$sb" ] \
          || complain "SIGS row for $u: $sa has no KEYS row with the fingerprint $sb"
        case " $gpg_keys " in *" $sa "*) ;; *) gpg_keys="$gpg_keys $sa" ;; esac
        # Inline exactly when the file is an APT row's InRelease.
        case " $apt_reads " in
          *" $u|$urow "*)
            if [ "$ss" = - ]; then inline_rows="$inline_rows $u|$urow"
            else complain "SIGS row for $u: $urow is an InRelease, signed inline, but the row names a detached '$ss'"; fi ;;
          *) [ "$ss" != - ] || complain "SIGS row for $u: an inline signature ('-') is only for an APT row's InRelease, not $urow" ;;
        esac ;;
      sigstore|sigcert)
        exact_identity "$u" "$sa"
        known_issuer "$u" "$sb"
        printf '%s' "$ss" | grep -qE '^https://[^[:space:]]+$' || complain "SIGS row for $u: '$ss' is not an https URL" ;;
      slsa)
        # The builder's identity is shared by every repository that uses it:
        # the source repository and ref are what make it this vendor's.
        exact_identity "$u" "$sa"
        known_issuer "$u" "$sb" https://token.actions.githubusercontent.com
        printf '%s' "$ss" | grep -qE '^https://[^[:space:]]+$' || complain "SIGS row for $u: '$ss' is not an https URL"
        printf '%s' "$sc" | grep -qxE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@refs/(tags|heads)/[A-Za-z0-9_.{}/-]+' \
          || complain "SIGS row for $u: '$sc' is not an exact owner/repo@refs/... binding" ;;
      ghattest)
        exact_identity "$u" "$sa"
        known_issuer "$u" "$sb" https://token.actions.githubusercontent.com
        if ! printf '%s' "$sc" | grep -qxE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+'; then
          complain "SIGS row for $u: '$sc' is not an owner/repo binding"
        else
          [ "$ss" = "https://api.github.com/repos/$sc/attestations" ] \
            || complain "SIGS row for $u: '$ss' is not the attestations API of $sc"
          case "$sa" in
            "https://github.com/$sc/.github/workflows/"*) ;;
            *) complain "SIGS row for $u: '$sa' is not a workflow of $sc" ;;
          esac
        fi ;;
      *) complain "SIGS row for $u: unknown method '$sm'" ;;
    esac
  done <<< "$SIGS"
  # An apt unit reads nothing from an InRelease that is not signed: each APT
  # row's must have its inline gpg row.
  for ar in $apt_reads; do
    case " $inline_rows " in
      *" $ar "*) ;;
      *) complain "${ar%%|*} reads ${ar#*|}, which has no inline gpg SIGS row" ;;
    esac
  done
  # An attested unit pins what it hashed only on the strength of a digest
  # row: without one for each download it would be trust on first use
  # classified as verified.
  while IFS='|' read -r u _ urow; do
    u=$(trim "$u"); [ -n "$u" ] || continue
    [ "$(unit_field "$u" 4 2>/dev/null || true)" = attested ] || continue
    urow=$(trim "$urow")
    case " $digest_rows " in
      *" $u|$urow "*) ;;
      *) complain "$u is attested, but $urow has no slsa, ghattest or sigcert row" ;;
    esac
  done <<< "$DOWNLOADS"
  # A unit that is signed at all is signed everywhere: every URL it reads has
  # its row, so a checksums file added beside a signed one cannot slip in
  # unverified.
  for u in $signed_units; do
    while IFS='|' read -r n _ urow _; do
      [ "$(trim "$n")" = "$u" ] || continue
      urow=$(trim "$urow")
      printf '%s\n' "$SIGS" | awk -F'|' -v u="$u" -v r="$urow" '
        { x = $1; y = $2; gsub(/[[:space:]]/, "", x); gsub(/[[:space:]]/, "", y); if (x == u && y == r) f = 1 } END { exit !f }' \
        || complain "$u is signed, but $urow has no SIGS row"
    done <<< "$(printf '%s\n%s\n' "$DOWNLOADS" "$SUMS")"
  done
  # Every key has a KEYS row -- a refresh URL, or an explicit `-` for none --
  # that a gpg row uses, an https URL, and a committed file that is still
  # exactly one primary key, the pinned one.
  local kn kf ku kfmt key_rows="" kf_path got
  while IFS='|' read -r kn kf ku kfmt; do
    kn=$(trim "$kn"); [ -n "$kn" ] || continue
    kf=$(trim "$kf"); ku=$(trim "$ku"); kfmt=$(trim "$kfmt")
    case " $key_rows " in *" $kn "*) complain "KEYS has two rows for $kn" ;; esac
    key_rows="$key_rows $kn"
    printf '%s' "$kf" | grep -qxE '[0-9A-F]{40}' || complain "KEYS row for $kn: '$kf' is not a full key fingerprint"
    case "$ku" in
      -) [ "$kfmt" = - ] || complain "KEYS row for $kn: no refresh URL, so its format must be '-', not '$kfmt'" ;;
      *)
        printf '%s' "$ku" | grep -qxE 'https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~%/+-]*)?' \
          || complain "KEYS row for $kn: '$ku' is not an https URL (or '-' for none)"
        case "$kfmt" in armor|html) ;; *) complain "KEYS row for $kn: '$kfmt' is not a key format (armor or html)" ;; esac ;;
    esac
    case " $gpg_keys " in *" $kn "*) ;; *) complain "KEYS row for $kn, which no gpg SIGS row uses" ;; esac
    kf_path="$script_dir/keys/$kn"
    if [ ! -f "$kf_path" ]; then
      complain "KEYS row for $kn: scripts/keys/$kn does not exist"
    elif command -v gpg >/dev/null; then
      got=$(primaries_of "$kf_path" | paste -sd' ' -)
      [ "$got" = "$kf" ] || complain "scripts/keys/$kn is not exactly one primary key, $kf (it holds: ${got:-no key})"
    else
      log warn "gpg not installed: scripts/keys/$kn not checked against $kf"
    fi
  done <<< "$KEYS"
  for kf_path in "$script_dir"/keys/*; do
    [ -e "$kf_path" ] || continue
    kn=$(basename "$kf_path")
    case " $key_rows " in *" $kn "*) ;; *) complain "scripts/keys/$kn has no KEYS row (a refresh URL, or '-' for none)" ;; esac
  done
  [ "$bad" -eq 0 ] || { log error "$bad problem(s) in the tables"; return 1; }
  log info "tables consistent with $root"
}
if [ "$check" -eq 1 ]; then
  check_tables
  exit $?
fi

# --- --refresh-keys: every key, with no version bump -------------------------
# One row, unit `signing-keys`: every KEYS row's key refreshed (refresh_key),
# exactly as a bump would before verifying with it. `bumped` (class auto)
# when any key gained something, and the merged keys written to
# scripts/keys; `current` when none did, or their vendors could not be
# reached (a warning each); `error` when any vendor's copy is not exactly the
# pinned key, or revokes it -- and then nothing is written. old and new are
# digests of the keys before and after (sha256 of their exports, in table
# order), so pin-bump-prs.sh can tell one refresh from the next. With --plan,
# only `{unit, from, to}` when a key changed, and nothing is written.
readonly KEYS_UNIT=signing-keys
refresh_all_keys() {
  local name fpr errs="" changed=() n edit=""
  local old="" new=""
  emit_integrity=keys
  : > "$tmp/keys.old"; : > "$tmp/keys.new"
  command -v gpg >/dev/null || { fail_unit "$KEYS_UNIT" "gpg is needed to refresh the signing keys"; return 0; }
  while IFS='|' read -r name fpr _; do
    name=$(trim "$name"); fpr=$(trim "$fpr")
    [ -n "$name" ] || continue
    key_source "$name" "$fpr"
    if [ ! -f "$key_path" ]; then errs="${errs}$name is missing; "; continue; fi
    if [ "$(primaries_of "$key_path")" != "$key_fpr" ]; then
      errs="${errs}$key_path is not exactly the key $key_fpr; "; continue
    fi
    if ! refresh_key "$key_path" "$name" "$key_fpr"; then
      errs="${errs}$(cat "$tmp/key.$name/failed"); "; continue
    fi
    cat "$key_base" >> "$tmp/keys.old"; cat "$key_ring" >> "$tmp/keys.new"
    if [ -n "$key_src" ]; then integrity_urls+=("$key_src"); fi
    if [ "$key_changed" = 1 ]; then changed+=("$name"); fi
  done <<< "$KEYS"
  if [ -n "$errs" ]; then fail_unit "$KEYS_UNIT" "${errs%; }"; return 0; fi
  old=$(sha256_of "$tmp/keys.old" | cut -c1-16); new=$(sha256_of "$tmp/keys.new" | cut -c1-16)
  if [ "${#changed[@]}" -eq 0 ]; then
    [ "$plan" -eq 1 ] || emit "$KEYS_UNIT" current "$old" "$new" "" "every signing key is as its vendor publishes it (or its vendor could not be reached)" ""
    return 0
  fi
  if [ "$plan" -eq 1 ]; then
    jq -nc --arg unit "$KEYS_UNIT" --arg from "$old" --arg to "$new" '{unit:$unit, from:$from, to:$to}'
    return 0
  fi
  for n in "${changed[@]}"; do
    write_key "$n"
    pin_values+=("scripts/keys/$n#sha256=$(sha256_of "$tmp/key.$n/merged.asc")")
    edit="${edit:+$edit, }$n"
  done
  log info "$KEYS_UNIT: refreshed $edit"
  emit "$KEYS_UNIT" bumped "$old" "$new" auto \
    "$edit refreshed from the vendor's official copy, which renews or adds to the committed key: each fetched key was exactly the pinned primary key, merged into the committed one by gpg (which imports only what that key itself signed), and carries no revocation" ""
}
if [ "$refresh_keys" -eq 1 ]; then
  refresh_all_keys
  if [ "$plan" -eq 1 ]; then
    cat "$results"
  elif [ "$format" = json ]; then
    jq -s . "$results"
  else
    jq -r '[.unit, .status, (.old // "-"), (.new // "-"), (.class // "-"), (.error // .reason)] | @tsv' "$results"
  fi
  [ "$errors" -eq 0 ] || exit 1
  exit 0
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
