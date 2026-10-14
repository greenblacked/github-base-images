#!/usr/bin/env bash
# The vulnerability gate's decision: does this build ADD a fixable HIGH/CRITICAL
# vulnerability that the image currently published under the same tag does not
# already carry? (docs/adr/0008-self-updating.md)
#
#   ./scripts/vuln-gate.sh --label "ci-node22 (amd64)" \
#       --candidate gate-candidate.json \
#       --baseline gate-baseline.json --baseline-ref ghcr.io/o/ci-node22@sha256:... \
#       --summary gate.md [--result gate.json]
#
#   ./scripts/vuln-gate.sh --label ... --candidate gate-candidate.json \
#       --no-baseline "ghcr.io/o/ci-new:bookworm-v1 has never been published" \
#       --summary gate.md
#
#   either of the above, plus the base image the build is FROM:
#       --upstream gate-upstream.json --upstream-ref mcr.microsoft.com/dotnet/sdk@sha256:...
#
# Every input is a Trivy JSON report (`--format json`) for the same
# architecture: the candidate this run just built, the image currently
# published for that tag (its per-arch digest), and optionally the base image
# the candidate was built FROM (its per-arch digest). build-image.yml produces
# all three with the same Trivy binary, the same on-disk database and the
# same flags -- HIGH,CRITICAL, ignore-unfixed, os,library, and the image's
# entries from .github/vuln-exceptions.json -- so every finding in any of them
# is one the old absolute gate would have failed on. This script only
# compares them.
#
# Why compare at all. The absolute gate failed whenever the image carried any
# fixable finding, including ones inside upstream software no release had
# fixed yet: urllib3 vendored in pip, brace-expansion and undici bundled in
# npm, PyJWT inside the Azure CLI. Those turned the rebuild red for every
# image that carried them, so the rebuild that delivers Debian's security
# updates published nothing at all for those images -- the gate held back
# exactly the fixes it exists to deliver. Now a build is blocked only for
# what it introduces; what it inherits from upstream ships until upstream
# fixes it, and is listed on every run.
#
# A finding's identity is (VulnerabilityID, PkgName, type), where type is
# the Trivy result's Type (debian, ubuntu, node-pkg, python-pkg, gobinary,
# jar, ...), or its Class when there is no Type:
#   - new     in the candidate, not in the baseline: BLOCKS. This build
#             introduced it (a new tool, a bumped pin, a newer base that
#             regressed), and this repository can decide not to ship that.
#   - known   in both: listed, never blocks. The published image already has
#             it, so not publishing would only keep the same finding out
#             there while also withholding whatever else this build fixes.
#             The same CVE in the same package at a different installed
#             version is still known: a patch-level move of a package that is
#             still vulnerable is not a regression.
#   - inherited  in the candidate and in the base image (--upstream), but
#             not in the baseline: listed, never blocks. See below.
#   - fixed   in the baseline only: listed, as what this build fixes.
# So what blocks is the candidate minus the published image minus the base
# image. A finding both the published image and the base image carry is
# counted as known, not inherited: inherited lists exactly what the base
# image alone excuses -- what the published comparison by itself would have
# blocked -- so that list is the whole of what the second baseline lets
# through, and can be read as such.
# The type is in the identity so a CVE known in one ecosystem cannot hide the
# same id newly reported against a same-named package in another: openssl the
# Debian package and an npm package called openssl are different software,
# and so are a Go module and a pip package that share a name. The identity
# deliberately ignores the path: the same vulnerable package of the same type
# appearing in one more place is not a new decision. That is the one way a
# known finding can grow without blocking, and it is accepted.
#
# Why the base image too. Comparing with the published image alone still
# blocks whatever a NEWER BASE brings with it, and that is not this
# repository's to fix either. The .NET SDK 8.0.426 image ships its own copies
# of Microsoft.Build.Tasks.Core and System.Security.Cryptography.Xml under
# usr/share/dotnet/sdk/, with fixable advisories against them; the published
# ci-dotnet8, built on the previous SDK, does not have them, so they read as
# new and blocked -- including the daily rebuild on main that carried twelve
# runtime fixes, two of them CRITICAL. A new image is worse off: with no
# published image to compare with, everything its base ships blocks. Nothing
# in this repository can change what Microsoft or Docker put in a base image;
# blocking on it only withholds the fixes the rebuild does carry, and the
# base's own fixes arrive the way every upstream fix does, through the daily
# rebuild that re-mirrors the base. What the build ADDS on top of the base --
# a tool, a pin, a package -- is still judged exactly as before.
#
# --upstream is additive and optional: without it, or when the workflow could
# not resolve or scan the base, the comparison is exactly the published one
# (or the strict one) described here. It works with --baseline and with
# --no-baseline alike: for a new image, findings the base image carries are
# inherited, and everything else is still strict.
#
# --no-baseline is the strict case: an empty baseline, so every finding is new
# and blocks, exactly as the absolute gate did. The workflow uses it whenever
# there is no published image to compare with -- a new image, a new contract
# tag -- AND whenever the published image could not be read or scanned. Those
# last cases are not "nothing to compare with" but "could not look", and the
# strict gate is the only answer to that which can never pass a build that a
# successful comparison would have failed. The reason is required and is
# printed, so a strict run says why it was strict.
#
# Exit codes:
#   0  no new finding; the summary lists the known and fixed ones
#   1  could not decide: an input (any of the three) missing, unreadable,
#      empty, not a Trivy JSON report (SchemaVersion 2), or a finding with no VulnerabilityID or
#      PkgName. Never read as a pass: a report that parsed as "no findings"
#      because its shape changed would be a gate that passed without looking.
#   2  usage
#   3  one or more new findings (listed in the summary)
#
# Requires jq. No network, no Trivy: it reads two or three files and writes
# one or two.
set -Eeuo pipefail

readonly EXIT_NEW=3
# The step summary is capped at 1 MiB per step, and a step over it loses its
# whole summary. A Trivy table for the Node or cloud images is well past that,
# which is why nothing here ever prints a full report: every list below is cut
# at a fixed number of rows, and every cell at a fixed length, so the summary
# stays a few tens of KiB however large the scan was. The --result JSON and
# the scan reports themselves (artifacts) carry everything.
readonly MAX_ROWS=50
readonly MAX_KNOWN_INLINE=40
readonly MAX_CELL=160

usage() {
  cat <<'EOF'
usage: vuln-gate.sh --label TEXT --candidate FILE
                    (--baseline FILE [--baseline-ref REF] | --no-baseline REASON)
                    [--upstream FILE --upstream-ref REF]
                    --summary FILE [--result FILE]

  --label         what was scanned, for headings (e.g. "ci-node22 (amd64)")
  --candidate     Trivy JSON report of the image this run built
  --baseline      Trivy JSON report of the image currently published
  --baseline-ref  the published image's reference, for the summary
  --no-baseline   no baseline: every finding blocks; REASON says why
  --upstream      Trivy JSON report of the base image the build is FROM:
                  what it carries is inherited, never blocking
  --upstream-ref  the base image's reference, for the summary (required
                  with --upstream)
  --summary       where to write the Markdown summary
  --result        also write {new, known, inherited, fixed} as JSON here

Exit: 0 nothing new, 1 could not decide, 2 usage, 3 new findings.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage_error() { printf 'error: %s\n' "$*" >&2; usage >&2; exit 2; }

label="" candidate="" baseline="" baseline_ref="" no_baseline="" no_baseline_set="" summary="" result=""
upstream="" upstream_ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --label|--candidate|--baseline|--baseline-ref|--no-baseline|--upstream|--upstream-ref|--summary|--result)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      case "$1" in
        --label) label="$2" ;;
        --candidate) candidate="$2" ;;
        --baseline) baseline="$2" ;;
        --baseline-ref) baseline_ref="$2" ;;
        --no-baseline) no_baseline="$2"; no_baseline_set=1 ;;
        --upstream) upstream="$2" ;;
        --upstream-ref) upstream_ref="$2" ;;
        --summary) summary="$2" ;;
        --result) result="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
[ -n "$label" ] || usage_error "--label is required"
[ -n "$candidate" ] || usage_error "--candidate is required"
[ -n "$summary" ] || usage_error "--summary is required"
if [ -n "$baseline" ] && [ -n "$no_baseline_set" ]; then
  usage_error "--baseline and --no-baseline are mutually exclusive"
fi
if [ -z "$baseline" ] && [ -z "$no_baseline_set" ]; then
  usage_error "one of --baseline or --no-baseline is required"
fi
if [ -n "$no_baseline_set" ] && [ -z "$no_baseline" ]; then
  usage_error "--no-baseline needs a reason: a strict run must say why it is strict"
fi
if [ -n "$upstream" ] && [ -z "$upstream_ref" ]; then
  usage_error "--upstream needs --upstream-ref: a finding excused as inherited must name what it was inherited from"
fi
if [ -z "$upstream" ] && [ -n "$upstream_ref" ]; then
  usage_error "--upstream-ref without --upstream"
fi

command -v jq >/dev/null || die "required command not found: jq"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
# Anything unexpected past this point is a failure to decide, and says so as
# exit 1 -- never as jq's own status, and never as a half-written summary.
trap 'printf "error: vuln-gate.sh failed at line %s -- no decision\n" "$LINENO" >&2; exit 1' ERR

# Validate a Trivy JSON report and flatten it to one record per finding.
#
# What is accepted is exactly Trivy's JSON schema 2: one object, SchemaVersion
# 2, a string ArtifactName, `Results` absent, null or an array of objects, each
# result's `Vulnerabilities` absent, null or an array, and every finding an
# object with a non-empty VulnerabilityID and PkgName. Absent Results and
# absent Vulnerabilities are how Trivy writes "nothing found", so they are
# valid and mean zero findings. Anything else is exit 1 -- in particular a
# future schema, which could put the findings somewhere this does not look.
load() { # FILE DEST WHAT
  local src="$1" dest="$2" what="$3"
  if [ ! -f "$src" ] || [ ! -r "$src" ]; then
    die "$what report $src does not exist or cannot be read"
  fi
  if ! jq -s '
      if length != 1 then error("expected exactly one JSON value, got \(length)") else .[0] end
      | if type != "object" then error("not a JSON object")
        elif .SchemaVersion != 2 then error("SchemaVersion is \(.SchemaVersion | tojson), expected 2")
        elif (.ArtifactName | type) != "string" then error("no ArtifactName")
        elif ((.Results // []) | type) != "array" then error("Results is not an array")
        else
          [ (.Results // [])[]
            | if type != "object" then error("a Results entry is not an object") else . end
            | (.Target // "") as $target
            | ((.Type // .Class // "") | tostring) as $type
            | (.Vulnerabilities // [])
            | if type != "array" then error("Vulnerabilities of \($target | tojson) is not an array") else . end
            | .[]
            | if type != "object"
                 or ((.VulnerabilityID | type) != "string") or .VulnerabilityID == ""
                 or ((.PkgName | type) != "string") or .PkgName == ""
              then error("a finding in \($target | tojson) has no VulnerabilityID or PkgName")
              else . end
            | { id: .VulnerabilityID,
                pkg: .PkgName,
                type: $type,
                sev: ((.Severity // "UNKNOWN") | tostring),
                installed: ((.InstalledVersion // "") | tostring),
                fixed: ((.FixedVersion // "") | tostring),
                target: ($target | tostring),
                path: ((.PkgPath // "") | tostring) } ]
        end' "$src" > "$dest" 2> "$tmp/load.err"; then
    die "$what report $src is not a usable Trivy JSON report: $(tr '\n' ' ' < "$tmp/load.err" | cut -c1-300)"
  fi
}

load "$candidate" "$tmp/cand.json" candidate
if [ -n "$baseline" ]; then
  load "$baseline" "$tmp/base.json" baseline
else
  echo '[]' > "$tmp/base.json"
fi
# The base image is validated exactly like the other two: a base report that
# cannot be read is exit 1, not "the base carries nothing" -- which would be
# safe, but would hide that the workflow handed over something broken.
if [ -n "$upstream" ]; then
  load "$upstream" "$tmp/up.json" "base image"
else
  echo '[]' > "$tmp/up.json"
fi

# One entry per identity in each class, with the versions, fixed versions and
# targets it was seen at gathered into lists. Severity is the worst seen.
# `inherited`, like `new` and `known`, is shown at the candidate's versions
# and targets: what is about to ship, not what the base image had.
jq -n --slurpfile c "$tmp/cand.json" --slurpfile b "$tmp/base.json" --slurpfile u "$tmp/up.json" '
  def key: [.id, .pkg, .type];
  def sevrank: {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}[.] // 4;
  def grouped: group_by(key) | map({
      id: .[0].id, pkg: .[0].pkg, type: .[0].type,
      sev: (map(.sev) | min_by(sevrank)),
      installed: (map(.installed) | unique | map(select(. != ""))),
      fixed: (map(.fixed) | unique | map(select(. != ""))),
      targets: (map(.target) | unique | map(select(. != "")))
    }) | sort_by((.sev | sevrank), .id, .pkg, .type);
  $c[0] as $cand | $b[0] as $base | $u[0] as $up
  | ($base | map(key) | unique) as $bk
  | ($up | map(key) | unique) as $uk
  | ($cand | map(key) | unique) as $ck
  | { new:       ($cand | map(select(key as $k | ($bk | bsearch($k) < 0) and ($uk | bsearch($k) < 0))) | grouped),
      known:     ($cand | map(select(key as $k | $bk | bsearch($k) >= 0)) | grouped),
      inherited: ($cand | map(select(key as $k | ($bk | bsearch($k) < 0) and ($uk | bsearch($k) >= 0))) | grouped),
      fixed:     ($base | map(select(key as $k | $ck | bsearch($k) < 0)) | grouped) }
' > "$tmp/cmp.json"

n_new=$(jq '.new | length' "$tmp/cmp.json")
n_known=$(jq '.known | length' "$tmp/cmp.json")
n_inherited=$(jq '.inherited | length' "$tmp/cmp.json")
n_fixed=$(jq '.fixed | length' "$tmp/cmp.json")
n_cand=$(jq 'length' "$tmp/cand.json")

if [ -n "$result" ]; then
  jq --arg label "$label" --arg ref "$baseline_ref" --arg none "$no_baseline" --arg up "$upstream_ref" \
    '{label: $label,
      baseline: (if $none != "" then {ref: null, strict: true, reason: $none}
                 else {ref: (if $ref == "" then null else $ref end), strict: false} end),
      upstream: (if $up == "" then null else {ref: $up} end)}
     + .' "$tmp/cmp.json" > "$tmp/result.json"
  mv "$tmp/result.json" "$result"
fi

# Shared Markdown helpers: a table-safe, length-capped cell, and a list of
# values cut to a few with a count of the rest. Every jq call using them is
# given $mc, the cell length cap. The $ names are jq's, not the shell's.
# shellcheck disable=SC2016
readonly JQ_LIB='
  def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|")
    | if length > $mc then .[:$mc] + "…" else . end;
  def few($n): if length > $n then (.[:$n] | join(", ")) + ", +\(length - $n) more" else join(", ") end;
  def row: "| \(.id | cell) | \(.pkg | cell) | \(.type | cell) | \(.sev | cell) | \(.installed | few(3) | cell) | \(.fixed | few(3) | cell) | \(.targets | few(2) | cell) |";
'

{
  echo "### Vulnerability gate: $label"
  echo
  if [ -n "$no_baseline_set" ]; then
    if [ -n "$upstream" ]; then
      echo "**Strict: no baseline.** $no_baseline. Every fixable HIGH/CRITICAL finding blocks, as if"
      echo "nothing had been published before -- except those the base image already carries."
    else
      echo "**Strict: no baseline.** $no_baseline. Every fixable HIGH/CRITICAL finding blocks, as if"
      echo "nothing had been published before."
    fi
  else
    echo "Compared with the image published now${baseline_ref:+: \`$baseline_ref\`}. Only findings this build"
    echo "adds block; the ones the published image already carries are known upstream and ship until"
    echo "upstream fixes them."
  fi
  if [ -n "$upstream" ]; then
    echo
    echo "Also compared with the base image this build is FROM: \`$upstream_ref\`. What the base"
    echo "image ships is inherited -- listed, never blocking: this repository cannot fix it, and the"
    echo "daily rebuild picks up the base's fixes when upstream publishes them."
  fi
  echo
  echo "| | findings |"
  echo "|---|---:|"
  echo "| **new in this build (blocking)** | **$n_new** |"
  echo "| known upstream (published image has them too) | $n_known |"
  if [ -n "$upstream" ]; then
    echo "| inherited from the base image (not blocking) | $n_inherited |"
  fi
  echo "| fixed by this build | $n_fixed |"
  echo
  echo "Counted per (vulnerability, package, package type); $n_cand candidate row(s) in all. Scope: fixable"
  echo "HIGH/CRITICAL, OS packages and libraries, after this image's exceptions."

  if [ "$n_new" -gt 0 ]; then
    echo
    echo "#### New in this build -- blocking"
    echo
    echo "| vulnerability | package | type | severity | installed | fixed in | where |"
    echo "|---|---|---|---|---|---|---|"
    jq -r --argjson max "$MAX_ROWS" --argjson mc "$MAX_CELL" "$JQ_LIB"'.new[:$max][] | row' "$tmp/cmp.json"
    if [ "$n_new" -gt "$MAX_ROWS" ]; then
      echo
      echo "...and $((n_new - MAX_ROWS)) more; the job log and the vuln-gate artifact have every one."
    fi
  fi

  if [ "$n_inherited" -gt 0 ]; then
    echo
    echo "#### Inherited from the base image (not blocking)"
    echo
    echo "| vulnerability | package | type | severity | installed | fixed in | where |"
    echo "|---|---|---|---|---|---|---|"
    jq -r --argjson max "$MAX_ROWS" --argjson mc "$MAX_CELL" "$JQ_LIB"'.inherited[:$max][] | row' "$tmp/cmp.json"
    if [ "$n_inherited" -gt "$MAX_ROWS" ]; then
      echo
      echo "...and $((n_inherited - MAX_ROWS)) more in the vuln-gate artifact."
    fi
  fi

  if [ "$n_fixed" -gt 0 ]; then
    echo
    echo "#### Fixed by this build"
    echo
    echo "| vulnerability | package | type | severity | was installed | fixed in | where |"
    echo "|---|---|---|---|---|---|---|"
    jq -r --argjson max "$MAX_ROWS" --argjson mc "$MAX_CELL" "$JQ_LIB"'.fixed[:$max][] | row' "$tmp/cmp.json"
    if [ "$n_fixed" -gt "$MAX_ROWS" ]; then
      echo
      echo "...and $((n_fixed - MAX_ROWS)) more in the vuln-gate artifact."
    fi
  fi

  if [ "$n_known" -gt 0 ]; then
    echo
    echo "#### Known upstream (not blocking)"
    echo
    printf '%s\n' "$(jq -r --argjson max "$MAX_KNOWN_INLINE" --argjson mc "$MAX_CELL" "$JQ_LIB"'
      .known | map("\(.id) (\(.pkg), \(.type))" | cell) | few($max)' "$tmp/cmp.json")."
    echo
    echo "Each is also an open alert in *Security → Code scanning* and in the security alerts report."
  fi
} > "$tmp/summary.md"
mv "$tmp/summary.md" "$summary"

# The log gets every new finding, uncapped: the log has no size limit, and a
# blocked build should name all of what blocked it in one place.
if [ "$n_new" -gt 0 ]; then
  jq -r '.new[] | "new: \(.id) in \(.pkg) [\(.type)] (\(.sev)), installed \(.installed | join(", ")), fixed in \(.fixed | join(", ")), at \(.targets | join(", "))"' \
    "$tmp/cmp.json" >&2
fi
printf 'vuln-gate: %s: %d new, %d known upstream, %s%d fixed%s\n' \
  "$label" "$n_new" "$n_known" "${upstream:+$n_inherited inherited from the base image, }" "$n_fixed" \
  "${no_baseline_set:+ (strict: no baseline)}"

if [ "$n_new" -gt 0 ]; then
  exit "$EXIT_NEW"
fi
exit 0
