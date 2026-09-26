#!/usr/bin/env bash
# Scan a Trivy CycloneDX SBOM with osv-scanner and write the findings as SARIF.
#
# A second opinion on the image, from a different vulnerability database (OSV,
# which aggregates the Debian and Ubuntu security trackers alongside the
# language ecosystems' own advisories), without a second image scan: the input
# is the SBOM build-image.yml already produces. Report-only -- the caller
# uploads the SARIF to code scanning and never gates on its contents.
#
# Report-only is not the same as "cannot fail". Findings are the expected
# outcome and exit 0. A scan that did not actually look -- the tool could not
# run, could not read the SBOM, could not reach the database -- exits non-zero,
# and the SARIF is deleted so nothing downstream can upload it as a clean scan.
# That is not hypothetical: with api.osv.dev unreachable, osv-scanner v2.6.0
# still writes a well-formed SARIF with zero results before exiting 127.
#
#   ./scripts/osv-scan-sbom.sh sbom-ci-tools-amd64.cdx.json osv-ci-tools-amd64.sarif
#
# Why the SBOM is rewritten before scanning
# -----------------------------------------
# Scanning Trivy's SBOM as-is reports nothing for any Debian package, on any
# image, ever -- verified with v2.6.0 against a real `trivy image` SBOM of
# debian:bookworm-slim, offline database: 88 packages read, 0 findings,
# exit 0. Two reasons, both about how a Trivy purl maps onto an OSV record:
#
#   1. Trivy writes the point release into the purl (`distro=debian-12.15`),
#      which osv-scanner turns into the ecosystem `Debian:12.15`. OSV files
#      Debian records under the major release only (`Debian:12`), so nothing
#      matches. Normalising to `debian-12` took the same SBOM from 0 findings
#      to 27. (Ubuntu purls already carry what OSV expects, `ubuntu-24.04`,
#      and are left alone.)
#   2. OSV's Debian and Ubuntu records are keyed by SOURCE package, while the
#      purl names the binary package. Anything whose binary name differs from
#      its source -- libc6 (glibc), libssl3 (openssl), libsystemd0 (systemd),
#      zlib1g (zlib) -- never matched, however the distro was spelled. Trivy
#      records the source name, version, release and epoch as properties on
#      each component; rewriting the purl from them took the same SBOM from
#      27 findings to 109 (Debian) and from 8 to 36 (ubuntu:noble).
#
# The rewrite is a copy; the SBOM artifact itself is not touched. Any Debian
# component whose distro qualifier cannot be read is a hard error, not a
# component silently left in the unmatched form.
#
# Exit codes:
#   0  scan completed and SARIF written -- with or without findings
#   1  the scan did not complete, or its output is unusable; no SARIF left behind
#   2  bad usage
set -euo pipefail

usage() {
  echo "usage: osv-scan-sbom.sh <sbom.cdx.json> <out.sarif>" >&2
}

[ $# -eq 2 ] || { usage; exit 2; }
sbom="$1" out="$2"

for cmd in osv-scanner jq; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done

if [ ! -s "$sbom" ]; then
  echo "error: SBOM '$sbom' is missing or empty" >&2
  exit 1
fi

# Whatever happens below, a stale or partial SARIF from an earlier attempt must
# never be mistaken for this run's output.
rm -f "$out"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# osv-scanner picks its SBOM parser from the file NAME -- `*.cdx.json` is what
# selects CycloneDX -- so the rewritten copy must keep that suffix.
normalized="$tmp/sbom.cdx.json"

if ! jq '
  def prop($n): [(.properties // [])[] | select(.name == "aquasecurity:trivy:" + $n) | .value][0];
  .components |= map(
    if (.purl // "" | startswith("pkg:deb/")) then
      (.purl | capture("^pkg:deb/(?<ns>[^/]+)/").ns) as $ns
      | ((.purl | capture("[?&]distro=(?<d>[^&]+)").d)
          // error("no distro qualifier on \(.purl)")) as $distro
      | (if $ns == "debian" then
           (($distro | capture("^debian-(?<m>[0-9]+)") | "debian-" + .m)
             // error("unrecognised Debian distro \($distro) on \(.purl)"))
         else $distro end) as $d
      | (prop("SrcName") // .name) as $sn
      | (if prop("SrcVersion") then
           prop("SrcVersion") + (if prop("SrcRelease") then "-" + prop("SrcRelease") else "" end)
         else (.version | sub("^[0-9]+:"; "")) end) as $sv
      | (prop("SrcEpoch") // (.version | capture("^(?<e>[0-9]+):").e) // null) as $ep
      | .name = $sn
      | .version = ((if $ep then $ep + ":" else "" end) + $sv)
      | .purl = "pkg:deb/\($ns)/\($sn)@\($sv | @uri)?distro=\($d)"
                + (if $ep then "&epoch=\($ep)" else "" end)
      | .["bom-ref"] = .purl
    else . end)
  # Several binaries share one source package; one entry per source is enough.
  | .components |= unique_by(.purl // .["bom-ref"])
  # The graph references the old bom-refs, which the rewrite just replaced.
  | .dependencies = []
' "$sbom" > "$normalized"; then
  echo "error: could not normalise '$sbom' for osv-scanner (see the jq error above)" >&2
  exit 1
fi

rc=0
osv-scanner scan source --format sarif --output-file "$out" -L "$normalized" || rc=$?

# Exit codes are osv-scanner's own, from cmd/osv-scanner/internal/cmd/run.go
# at v2.6.0 -- not inferred from behaviour:
#   0    no vulnerabilities
#   1    vulnerabilities found (ErrVulnerabilitiesFound)
#   127  general error -- including a database it could not reach
#   128  no packages found (ErrNoPackagesFound) -- it read nothing it recognised
#   129  API query failed (ErrAPIFailed)
#   130  invalid config
# Anything else (126 not executable, a signal) is also a scan that did not run.
case "$rc" in
  0|1) ;;
  128)
    echo "error: osv-scanner found no packages in '$sbom' (exit 128) -- it read nothing it could scan" >&2
    rm -f "$out"; exit 1 ;;
  129)
    echo "error: osv-scanner could not query the OSV API (exit 129)" >&2
    rm -f "$out"; exit 1 ;;
  *)
    echo "error: osv-scanner failed (exit $rc) -- the scan did not complete" >&2
    rm -f "$out"; exit 1 ;;
esac

# A zero exit with no usable output is still a scan nobody can read.
if [ ! -s "$out" ] || ! jq -e '(.runs | type == "array") and (.runs | length > 0)' "$out" >/dev/null 2>&1; then
  echo "error: osv-scanner exited $rc but '$out' is missing, empty or not SARIF" >&2
  rm -f "$out"; exit 1
fi

results=$(jq '[.runs[].results[]?] | length' "$out")
packages=$(jq '[.components[]? | select(.purl)] | length' "$normalized")
echo "osv-scanner: exit $rc, $results result(s) across $packages package(s) from $sbom -> $out"
