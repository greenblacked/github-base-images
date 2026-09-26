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
# and both SARIF files are deleted so nothing downstream can upload them as a
# clean scan. That is not hypothetical: with api.osv.dev unreachable,
# osv-scanner v2.6.0 still writes a well-formed SARIF with zero results before
# exiting 127.
#
#   ./scripts/osv-scan-sbom.sh sbom-ci-tools-amd64.cdx.json full.sarif upload.sarif
#
# Two outputs:
#   full.sarif    every finding, every severity -- the 90-day artifact
#   upload.sarif  what goes to code scanning: findings whose rule scores
#                 security-severity >= 7.0 (HIGH/CRITICAL), PLUS every finding
#                 whose rule carries no score at all. The same readability
#                 trade as the Trivy SARIF (ADR 0003), but an unscored finding
#                 is not a low one -- dropping those would be a silent
#                 narrowing, so they are kept and counted separately.
#                 One exclusion on top: kernel findings on an image whose only
#                 package from the `linux` source is linux-libc-dev (see below).
# Counts (kept / dropped / unscored / kernel) go to stdout and, in Actions, to
# the step summary, so a scan that filtered down to nothing says so.
#
# Why kernel findings are kept out of the upload
# ----------------------------------------------
# Images that keep a compiler toolchain (libc6-dev, via build-essential or
# PHPIZE_DEPS: ci-go, ci-php84, ci-php85) carry linux-libc-dev -- the kernel's
# userspace API headers, built from Debian's `linux` source package. OSV files
# every kernel CVE under that source, so after the source-name mapping below
# each of those images reported roughly 2,000 kernel findings per
# architecture, against a package that contains no kernel code: a container
# runs the host's kernel, never one from its image. The upload therefore drops
# findings on the `linux` source, but only when linux-libc-dev is the ONLY
# binary package from that source in the SBOM. Anything else from it
# (linux-image-*, linux-perf, bpftool, usbip) is real kernel-built code, and
# then nothing is excluded. Excluded findings stay in full.sarif and are
# counted in the summary.
#
# osv-scanner v2.6.0 names a result's package only in its message text
# ("Package 'linux@6.1.187-1' is vulnerable to '...'"). When the exclusion
# applies, every result must parse that way; if one does not, the script
# fails rather than let a format change make the exclusion quietly match
# nothing.
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
#      each component (aquasecurity:trivy:SrcName, SrcVersion, SrcRelease,
#      SrcEpoch); the purl is rewritten from those.
#
# The source EPOCH is best-effort. When Trivy omits SrcEpoch, no epoch is
# used -- the binary's epoch is NOT borrowed, because it is not the source's:
# bsdutils is `1:2.38.1-5+deb12u3` while its source util-linux carries no
# epoch there, and borrowing it produced a second, differently-versioned
# util-linux row. osv-scalibr compares the component version and ignores the
# purl's epoch qualifier, so a wrong epoch is a wrong comparison, not a
# harmless annotation. Rows for one source package at one version are then
# merged, preferring the row whose epoch Trivy stated explicitly. (A binary
# with no SrcVersion at all falls back to its own full version, epoch
# included, since that is then the only version there is.)
#
# Tripwire: the source mapping depends on Trivy's property names. If a Trivy
# upgrade renamed them, every component would silently fall back to its binary
# name -- not zero findings, just fewer (27 instead of 98 on bookworm-slim),
# which nobody would notice. So when the SBOM has deb components and NONE of
# them carries SrcName, this fails rather than scanning the degraded form. The
# counts are printed either way.
#
# Why the rewritten copy lives at a FIXED path
# --------------------------------------------
# osv-scanner v2.6.0 (internal/output/sarif.go) fingerprints each result as
# sha256("<vulnID>:<artifact path>:<package>") and puts the same path in the
# result's location; it strips only a literal `/github/workspace/` prefix, and
# makes even a relative -L path absolute. A mktemp path therefore changed
# every fingerprint on every run, and code scanning would have closed every
# alert as "fixed" and opened it again as new, every build. The copy is
# written to /tmp/osv-scan-sbom/<input basename> -- the same absolute path on
# every runner and from any working directory -- and the displayed location is
# then rewritten to the bare basename. The fingerprint itself is left exactly
# as osv-scanner computed it. (Two local runs on the same basename at the same
# moment would share that file; the pipeline never does that, since each job
# scans one SBOM.)
#
# Exit codes:
#   0  scan completed and both SARIFs written -- with or without findings
#   1  the scan did not complete, or its output is unusable; no SARIF left behind
#   2  bad usage
set -euo pipefail

readonly SEVERITY_THRESHOLD=7.0
readonly WORKDIR=/tmp/osv-scan-sbom

usage() {
  echo "usage: osv-scan-sbom.sh <sbom.cdx.json> <full.sarif> <upload.sarif>" >&2
}

[ $# -eq 3 ] || { usage; exit 2; }
sbom="$1" out="$2" upload="$3"
normalized=""

# Anything that ends this script unsuccessfully -- an explicit exit 1 or an
# errexit from an unexpected failure -- takes both outputs with it.
cleanup() {
  local rc=$?
  [ -z "$normalized" ] || rm -f "$normalized"
  if [ "$rc" -ne 0 ]; then
    rm -f "$out" "$upload"
  fi
  # An errexit from some command's own status (jq's 5, say) is still "the
  # scan's output is unusable": keep the documented 0/1/2 contract.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ] && [ "$rc" -ne 2 ]; then
    echo "error: unexpected failure (exit $rc) -- see the message above; no SARIF left behind" >&2
    exit 1
  fi
  return "$rc"
}

base=$(basename -- "$sbom")
case "$base" in
  *.cdx.json) ;;
  # osv-scanner picks its SBOM parser from the file NAME -- `*.cdx.json` is
  # what selects CycloneDX -- and the rewritten copy keeps the input's name.
  *) echo "error: SBOM file name must end in .cdx.json, got '$base'" >&2; exit 2 ;;
esac

# Only after argument checks: a usage error (exit 2) has produced nothing, so
# it must not delete output files left by an earlier run.
trap cleanup EXIT

# In Actions, the summary lines also go to the step summary.
summary() {
  printf '%s\n' "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

for cmd in osv-scanner jq; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done

if [ ! -s "$sbom" ]; then
  echo "error: SBOM '$sbom' is missing or empty" >&2
  exit 1
fi

# Whatever happens below, a stale or partial SARIF from an earlier attempt must
# never be mistaken for this run's output.
rm -f "$out" "$upload"

# A fixed directory under a world-writable /tmp: create it private, and refuse
# one that is a symlink or belongs to someone else rather than write through it.
if [ ! -e "$WORKDIR" ] && [ ! -L "$WORKDIR" ]; then
  mkdir -m 0700 "$WORKDIR"
fi
if [ -L "$WORKDIR" ] || [ ! -d "$WORKDIR" ] || [ ! -O "$WORKDIR" ]; then
  echo "error: $WORKDIR is not a directory owned by this user -- refusing to use it" >&2
  exit 1
fi
normalized="$WORKDIR/$base"
rm -f "$normalized"

# --- tripwire: is the source mapping still fed? ------------------------------
counts=$(jq -r '
  [.components[]? | select(.purl // "" | startswith("pkg:deb/"))] as $deb
  | [$deb | length,
     ($deb | map(select([(.properties // [])[] | select(.name == "aquasecurity:trivy:SrcName")] | length > 0)) | length)]
  | @tsv' "$sbom") || { echo "error: could not read components from '$sbom'" >&2; exit 1; }
read -r deb_total deb_src <<<"$counts"
summary "OSV input $base: $deb_total deb component(s), $deb_src mapped by Trivy's SrcName, $((deb_total - deb_src)) by binary name (fallback)"
if [ "$deb_total" -gt 0 ] && [ "$deb_src" -eq 0 ]; then
  echo "error: none of the $deb_total deb components in '$sbom' carries aquasecurity:trivy:SrcName -- the source-package mapping is not being fed (a Trivy property rename?), and scanning by binary name would silently under-report" >&2
  exit 1
fi

# --- kernel headers: which binaries come from the `linux` source? ------------
linux_bins=$(jq -r '
  [.components[]? | select(.purl // "" | startswith("pkg:deb/"))
   | select(([(.properties // [])[] | select(.name == "aquasecurity:trivy:SrcName") | .value][0] // .name) == "linux")
   | .name] | unique | join(" ")' "$sbom") || { echo "error: could not read components from '$sbom'" >&2; exit 1; }
if [ "$linux_bins" = "linux-libc-dev" ]; then
  headers_only=true
else
  headers_only=false
  if [ -n "$linux_bins" ]; then
    summary "OSV: packages from the linux source other than linux-libc-dev ($linux_bins) -- kernel findings are NOT excluded from the upload"
  fi
fi

# --- normalise ---------------------------------------------------------------
if ! jq '
  def prop($n): [(.properties // [])[] | select(.name == "aquasecurity:trivy:" + $n) | .value][0];
  .components |= (
    map(
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
             [prop("SrcVersion") + (if prop("SrcRelease") then "-" + prop("SrcRelease") else "" end),
              prop("SrcEpoch")]
           else
             [(.version | sub("^[0-9]+:"; "")), (.version | capture("^(?<e>[0-9]+):").e // null)]
           end) as [$sv, $ep]
        | .name = $sn
        | .version = ((if $ep then $ep + ":" else "" end) + $sv)
        | .purl = "pkg:deb/\($ns)/\($sn)@\($sv | @uri)?distro=\($d)"
                  + (if $ep then "&epoch=\($ep)" else "" end)
        | .["bom-ref"] = .purl
        | ._osv_key = ["deb", $ns, $sn, $d, $sv]
        | ._osv_rank = (if prop("SrcEpoch") then 0 else 1 end)
      else
        ._osv_key = ["other", (.purl // .["bom-ref"])]
        | ._osv_rank = 0
      end)
    # One row per source package and version; an explicit SrcEpoch wins.
    | group_by(._osv_key)
    | map(sort_by(._osv_rank) | .[0] | del(._osv_key, ._osv_rank))
  )
  # The graph references the old bom-refs, which the rewrite just replaced.
  | .dependencies = []
' "$sbom" > "$normalized"; then
  echo "error: could not normalise '$sbom' for osv-scanner (see the jq error above)" >&2
  exit 1
fi

# --- scan --------------------------------------------------------------------
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
    exit 1 ;;
  129)
    echo "error: osv-scanner could not query the OSV API (exit 129)" >&2
    exit 1 ;;
  *)
    echo "error: osv-scanner failed (exit $rc) -- the scan did not complete" >&2
    exit 1 ;;
esac

# A zero exit with no usable output is still a scan nobody can read.
if [ ! -s "$out" ] || ! jq -e '(.runs | type == "array") and (.runs | length > 0)' "$out" >/dev/null 2>&1; then
  echo "error: osv-scanner exited $rc but '$out' is missing, empty or not SARIF" >&2
  exit 1
fi

# --- stable locations --------------------------------------------------------
# Display only: the location shows the SBOM's name, not /tmp/osv-scan-sbom/.
# partialFingerprints are not touched (see the header).
jq --arg base "$base" '
  .runs |= map(
    (if .artifacts then .artifacts |= map(.location.uri = $base) else . end)
    | .results |= map(.locations |= map(.physicalLocation.artifactLocation.uri = $base))
  )' "$out" > "$out.tmp"
mv "$out.tmp" "$out"

# --- the uploaded subset -----------------------------------------------------
# rules[] is left intact, so every kept result's ruleIndex stays valid. A
# security-severity that is present but not a number makes tonumber fail, and
# with it this script: an unreadable score is not silently read as "low".
sev_map='([(.tool.driver.rules // [])[] | {key: .id, value: (.properties["security-severity"] // null)}] | from_entries)'
# The package a result is about: the source package after normalisation, so
# `linux` for linux-libc-dev. null when the message does not parse.
pkg_of='(((.message.text // "") | capture("^Package '"'"'(?<p>.+)@[^@'"'"']*'"'"' is vulnerable to '"'"'") | .p) // null)'

if [ "$headers_only" = true ]; then
  unparsed=$(jq "[.runs[].results[] | select($pkg_of == null)] | length" "$out")
  if [ "$unparsed" -ne 0 ]; then
    echo "error: $unparsed result(s) in '$out' do not name their package as \"Package '<name>@<version>' is vulnerable to ...\" -- the linux-libc-dev exclusion cannot tell kernel findings apart (an osv-scanner output change?)" >&2
    exit 1
  fi
fi

jq --argjson t "$SEVERITY_THRESHOLD" --argjson hdr "$headers_only" "
  .runs |= map($sev_map as \$sev
    | .results |= map(select(
        (\$hdr and $pkg_of == \"linux\") | not)
      | select((\$sev[.ruleId]) as \$s | \$s == null or ((\$s | tonumber) >= \$t))))
" "$out" > "$upload"

# A command substitution, not `read < <(jq ...)`: errexit cannot see a failure
# inside a process substitution, and empty counts would sail through below.
tally=$(jq -r --argjson t "$SEVERITY_THRESHOLD" --argjson hdr "$headers_only" "
  [.runs[] | $sev_map as \$sev | .results[]
   | (\$sev[.ruleId]) as \$s
   | if \$hdr and $pkg_of == \"linux\" then \"kernel\"
     elif \$s == null then \"unscored\" elif (\$s | tonumber) >= \$t then \"kept\" else \"dropped\" end]
  | [length, (map(select(. == \"kept\")) | length),
     (map(select(. == \"dropped\")) | length), (map(select(. == \"unscored\")) | length),
     (map(select(. == \"kernel\")) | length)]
  | @tsv" "$out")
read -r total kept dropped unscored kernel <<<"$tally"
uploaded=$(jq '[.runs[].results[]] | length' "$upload")

# Two independent jq programs must agree on what was kept; if they do not, the
# filter is not doing what its counts claim.
if [ "$uploaded" -ne $((kept + unscored)) ] || [ "$total" -ne $((kept + dropped + unscored + kernel)) ]; then
  echo "error: SARIF filter disagrees with its own counts (total=$total kept=$kept dropped=$dropped unscored=$unscored kernel=$kernel uploaded=$uploaded)" >&2
  exit 1
fi

summary "OSV scan of $base: osv-scanner exit $rc, $total finding(s) in $(basename -- "$out") (all severities); uploading $uploaded to code scanning = $kept with security-severity >= $SEVERITY_THRESHOLD + $unscored with no score (kept, not dropped); $dropped below $SEVERITY_THRESHOLD kept only in the artifact"
if [ "$kernel" -gt 0 ]; then
  summary "OSV: $kernel kernel finding(s) on the linux source, whose only package here is linux-libc-dev (kernel headers; a container runs the host's kernel), kept only in the artifact"
fi
if [ "$total" -gt 0 ] && [ "$uploaded" -eq 0 ]; then
  summary "OSV: every finding was scored below $SEVERITY_THRESHOLD or excluded as a kernel-header finding, so the code-scanning upload is empty by the filter, not by the scan -- all $total are in the artifact"
fi
