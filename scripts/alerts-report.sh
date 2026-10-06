#!/usr/bin/env bash
# Turn the repository's open security alerts into one readable report.
#
# Security -> Code scanning is a flat list: every image, two architectures,
# a Trivy and an OSV upload per pair, plus the repository-level tools (CodeQL,
# zizmor, Scorecard, the repository secret scan). At that volume the list
# answers "how many" and nothing else. The questions that matter are
# different: which images carry what, which findings already have a fix (and
# so should never have shipped), which CVEs are everywhere because they live
# in a shared base, and which alerts belong to categories nothing uploads to
# any more. Dependabot's alerts sit on a separate page with the same problem.
# This script answers those from the two APIs' output alone, so it runs in CI
# and offline against saved files alike.
#
#   ./scripts/alerts-report.sh <code-scanning.json> <dependabot.json> <images.json> <exceptions.json> <report.md>
#
# The two alert files are the concatenated output of
#   gh api --paginate "repos/<owner>/<repo>/code-scanning/alerts?state=open&ref=refs/heads/main&per_page=100"
#   gh api --paginate "repos/<owner>/<repo>/dependabot/alerts?state=open&per_page=100"
# each of which prints one JSON array per page, back to back -- hence `jq -s`
# and a merge below rather than a plain parse.
#
# "Fixable" means a version to move to exists:
#   - a Trivy alert whose SARIF message carries a non-empty `Fixed Version:`
#     line: the set the vulnerability gate judges (OS packages and libraries,
#     HIGH/CRITICAL, ignore-unfixed). Since docs/adr/0008 the gate blocks only
#     the ones a build adds, so one open in a current image is usually known
#     upstream -- inherited from the runtime or a vendored package, with no
#     release that fixes it yet -- and otherwise means the image has not been
#     rebuilt since the fix appeared.
#   - a HIGH/CRITICAL Dependabot alert with a `first_patched_version` -- the
#     same rule applied to the repository's own dependencies.
# Either way it is worth listing, which is why it sets the exit code; the
# workflow turns that exit code into a warning, not a failure (see
# .github/workflows/alerts-report.yml for why).
#
# Except when an active exception covers it. <exceptions.json> is
# .github/vuln-exceptions.json, the same list the vulnerability gate turns
# into its Trivy ignore file: expiring, per-image, per-CVE entries for a
# finding whose fixed version exists in no released artifact yet
# (docs/adr/0006). A fixable HIGH/CRITICAL Trivy alert that an entry
# covers is "excepted": listed in its own section, counted separately, and
# never sets the exit code -- the report agrees with the gate instead of
# failing on what the gate lets through. An entry covers an alert only when
# all of these hold, which is the same narrowing the gate's Trivy ignore file
# applies:
#   - the alert's image and rule id are the entry's `image` and `id`;
#   - the entry has not expired: `expires` is after today (UTC), the same
#     boundary Trivy applies to `expired_at`. From that date on the entry
#     excuses nothing here either, and the report lists it as expired so it
#     gets removed or renewed;
#   - if the entry has `paths`: the alert's location is one of them. Trivy's
#     SARIF puts the package path, or the target when there is none, in the
#     result's location, which the API returns as
#     most_recent_instance.location.path;
#   - if the entry has `purls`: the alert's `Package:` and `Installed
#     Version:` lines equal the name and version of one of them.
# An entry with neither `paths` nor `purls` covers nothing (scripts/lint.sh
# rejects one). Where the report and the gate could still disagree -- a
# package name Trivy normalises in the PURL but not in the `Package:` line --
# the report is the stricter of the two, so it fails rather than excuses.
#
# GitHub's secret-scanning alerts are NOT read. No GITHUB_TOKEN permission
# grants that API, and this repository adds no PAT or app credential to reach
# it. The report says so in its own section, with what does cover secrets,
# rather than leaving a gap that reads as "no secrets found".
#
# Exit codes:
#   0  report written; no fixable HIGH/CRITICAL Trivy alert in any image that
#      is still in images.json (other than ones an active exception covers),
#      and no fixable HIGH/CRITICAL Dependabot alert
#   1  no trustworthy report: unreadable or malformed input (not JSON, not an
#      array of alert objects, no JSON value at all), images.json unreadable,
#      an exceptions file that is not one array of complete entries with
#      valid dates, or an alert whose fixability could not be decided (a
#      Trivy alert in a current image with no `Fixed Version:` line; a
#      Dependabot alert with no `security_vulnerability`). In that last case
#      the report IS written, with the undecidable alerts listed, but the run
#      must not read as clean -- a parser that stopped matching would
#      otherwise report "nothing fixable" for every alert it failed to read.
#   2  usage
#   3  report written; one or more fixable HIGH/CRITICAL alerts, listed in the
#      report. Outranks 1, the same precedence as check-published.sh: a
#      confirmed finding must not hide behind an unrelated parse problem.
#
# Stale alerts -- image-shaped code-scanning categories (`<image>-<arch>`,
# optionally `osv-`-prefixed) whose image is no longer in images.json -- are
# counted and listed but never affect the exit code. Nothing will ever upload
# to those categories again, so their alerts can never close on their own;
# they need a human to delete the category, not a rebuild.
#
# Requires jq (on every GitHub-hosted runner) and nothing else: no network,
# no token. The workflow does the fetching; this only reads files.
set -Eeuo pipefail

readonly EXIT_FIXABLE=3
# $GITHUB_STEP_SUMMARY is capped at 1 MiB per step, and a step that exceeds it
# gets its summary dropped with an error rather than truncated. Stay well
# clear, leaving room for the note that says where the rest went.
readonly SUMMARY_LIMIT=900000
readonly TOP_N=25

usage() {
  cat <<'EOF'
usage: alerts-report.sh <code-scanning.json> <dependabot.json> <images.json> <exceptions.json> <report.md>

  code-scanning.json  open code-scanning alerts on main, one or more
                      concatenated JSON arrays (`gh api --paginate` output)
  dependabot.json     open Dependabot alerts, in the same form
  images.json         the repository's .github/images.json
  exceptions.json     the repository's .github/vuln-exceptions.json
                      (`[]` for none)
  report.md           where to write the Markdown report

Appends the report to $GITHUB_STEP_SUMMARY when that is set. Reads
GITHUB_REPOSITORY and GITHUB_SERVER_URL, when set, for links.

Exit: 0 clean, 1 unreadable input or undecidable alerts, 2 usage,
      3 fixable HIGH/CRITICAL alerts not covered by an active exception.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ $# -ne 5 ]; then
  usage >&2
  exit 2
fi
cs_file="$1" dep_file="$2" images_file="$3" exc_file="$4" report_file="$5"

command -v jq >/dev/null || die "required command not found: jq"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
# Anything unexpected past this point is a failure to produce the report, and
# must say so as exit 1 -- not as jq's own exit status (2 would read as usage,
# 5 as nothing in particular), and never as a report that silently stopped
# halfway.
trap 'printf "error: alerts-report.sh failed at line %s -- no trustworthy report\n" "$LINENO" >&2; exit 1' ERR

for f in "$cs_file" "$dep_file" "$images_file" "$exc_file"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then die "cannot read input file: $f"; fi
done

# --- input validation ---------------------------------------------------------
#
# "Zero alerts" must mean the API said zero, never that the input was empty,
# truncated or the wrong shape. So: at least one JSON value (an empty file
# slurps to [], which `add // []` would otherwise turn into a clean report of
# nothing), every value an array (one per page), every element an object with
# a numeric .number (an error body like {"message": "..."} is an object, not an
# array, and fails here). unique_by(.number) keeps a page boundary that ever
# repeated an alert from counting it twice.
load_alerts() {
  local src="$1" dest="$2" what="$3"
  if ! jq -s '
      if length == 0 then error("no JSON value at all (empty input)")
      elif any(.[]; type != "array") then
        error("expected one or more JSON arrays, got: \(map(type) | unique | join(", "))")
      else add
        | if any(.[]; type != "object" or ((.number? // null) | type) != "number")
          then error("not every element is an alert object with a numeric .number")
          else unique_by(.number) end
      end' "$src" > "$dest" 2> "$tmp/load.err"; then
    die "$what input $src is not usable: $(tr '\n' ' ' < "$tmp/load.err" | cut -c1-300)"
  fi
}
load_alerts "$cs_file" "$tmp/cs.json" "code-scanning"
load_alerts "$dep_file" "$tmp/dep.json" "Dependabot"

if ! jq -e 'type == "array" and length > 0
            and all(.[]; type == "object" and ((.image? // null) | type) == "string")' \
      "$images_file" > /dev/null 2> "$tmp/images.err"; then
  die "images file $images_file is not a non-empty array of {image: ...} objects: $(tr '\n' ' ' < "$tmp/images.err" | cut -c1-300)"
fi
jq -c '[.[].image]' "$images_file" > "$tmp/images.json"

# Exceptions: one JSON array, possibly empty, of complete entries. Checked as
# strictly as the alert inputs, because a half-read exception list fails in
# the dangerous direction: a malformed entry the report skipped would turn an
# excepted alert back into a failure (noisy but safe), while one it misread --
# a date that parsed as something else -- could excuse an alert the gate no
# longer excuses. So anything short of well-formed is exit 1. The date check
# round-trips through strptime/strftime, which rejects 2026-02-31 as well as
# 2026-2-5. scripts/lint.sh checks the rest (known image, id shape, the
# 90-day limit, duplicates); none of that changes what this report may trust.
today=$(date -u +%Y-%m-%d)
if ! jq -s -e '
    def text: type == "string" and length > 0;
    def valid_date: type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
      and ((try (strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch null) == .);
    if length != 1 then error("expected exactly one JSON value, got \(length)") else .[0] end
    | if type != "array" then error("not a JSON array")
    elif any(.[]; type != "object") then error("not every element is an object")
    else (map(select(
        ([.image, .id, .package, .installed, .reason, .upstream] | all(text) | not)
        or (.expires | valid_date | not)
        or (has("paths") and ((.paths | type) != "array"
                              or any(.paths[]; (text | not) or startswith("/") or test("[*?\\[]"))))
        or (has("purls") and ((.purls | type) != "array"
                              or any(.purls[]; (text | not) or (test("^pkg:[a-z]+/[^@\\s]+@[^\\s]+$") | not))))))
      | if length > 0
        then error("\(length) entr\(if length == 1 then "y" else "ies" end) missing a field or with a bad date, paths or purls, first: \(.[0] | tojson | .[:200])")
        else true end)
    end' "$exc_file" > /dev/null 2> "$tmp/exc.err"; then
  die "exceptions file $exc_file is not usable: $(tr '\n' ' ' < "$tmp/exc.err" | cut -c1-400)"
fi
# `pkgs` is each purl split into the name and version the alert's message
# lines are compared with; the shape was validated above.
jq -c --arg today "$today" '
  map(. + {active: (.expires > $today),
           pkgs: [(.purls // [])[] | capture("^pkg:[a-z]+/(?<name>[^@]+)@(?<version>.+)$")]})' \
  "$exc_file" > "$tmp/exc.json"

# --- normalise ----------------------------------------------------------------
#
# One flat record per alert, so every section below is a query over the same
# shape instead of re-deriving category, image and fixability its own way.
#
# Trivy's SARIF message is fixed-format lines:
#   Package: openssl
#   Installed Version: 3.0.15-1
#   Vulnerability CVE-2025-1234
#   Severity: HIGH
#   Fixed Version: 3.0.16-1
#   Link: [CVE-2025-1234](https://...)
# Parsed by line prefix rather than regex anchors, whose multi-line behaviour
# differs between regex engines. `fixed_line` records whether the `Fixed
# Version:` line was there at all, as distinct from being there and empty --
# the difference between "no fix exists" and "could not tell".
#
# OSV alerts are counted per image but never judged fixable: osv-scanner's
# SARIF (build-image.yml's `osv` job) is a second opinion, reported only, and
# its message carries no fixed version in a form worth depending on.
jq --slurpfile images "$tmp/images.json" --slurpfile exc "$tmp/exc.json" '
  def field($k): [ split("\n")[] | select(startswith($k + ":"))
                   | ltrimstr($k + ":") | gsub("^\\s+|\\s+$"; "") ];
  # Whether exception entry `.` covers normalised alert $a (see the header).
  def covers($a):
    .active and .image == $a.image and .id == $a.rule
    and (has("paths") or has("purls"))
    and ((has("paths") | not) or any(.paths[]; . == $a.path))
    and ((has("purls") | not) or any(.pkgs[]; .name == $a.pkg and .version == $a.installed));
  $images[0] as $current
  | map(
      ((.most_recent_instance.category // "") | sub("/+$"; "")) as $cat
      | (.tool.name // "") as $tool
      | ($tool | ascii_downcase) as $tl
      | (.most_recent_instance.message.text // "") as $msg
      | (($cat | capture("^(?<osv>osv-)?(?<image>.+)-(?<arch>amd64|arm64)$")) // null) as $m
      | ($msg | field("Fixed Version")) as $fixed
      | {
          number,
          url: (.html_url // ""),
          tool: (if $tool == "" then "(unknown)" else $tool end),
          rule: (.rule.id // "(none)"),
          sev: ((.rule.security_severity_level // "") | ascii_downcase
                | if IN("critical", "high", "medium", "low") then . else "other" end),
          category: (if $cat == "" then "(none)" else $cat end),
          image: ($m.image // null),
          arch: ($m.arch // null),
          kind: (if $m == null then "repo"
                 elif any($current[]; . == $m.image) then "image"
                 else "stale" end),
          trivy: ($tl == "trivy"),
          osv: (($tl | startswith("osv")) or (($m.osv // "") != "")),
          pkg: (($msg | field("Package"))[0] // ""),
          installed: (($msg | field("Installed Version"))[0] // ""),
          path: (.most_recent_instance.location.path // ""),
          fixed_line: ($fixed | length > 0),
          fixed: ($fixed[0] // "")
        }
      | .looks_image = ($m == null
          and any($current[]; . as $i | ($cat | ltrimstr("osv-")) | startswith($i)))
      | .trivy_image = (.trivy and .kind == "image" and (.osv | not))
      | .fixable = (.trivy_image and .fixed != "")
      # An active exception that covers this alert: the gate skips it, so
      # this report lists it without failing on it.
      | . as $a
      | .exception = (if .fixable and (.sev == "critical" or .sev == "high")
                      then first($exc[0][] | select(covers($a))) // null
                      else null end)
      | .excepted = (.exception != null)
      | .gating = (.fixable and (.sev == "critical" or .sev == "high") and (.excepted | not))
      # Undecidable: this report cannot tell whether the alert should fail it.
      # Each case is a shape change that would otherwise read as "nothing
      # fixable" -- a check passing because it failed to look.
      | .why = (if .trivy_image and (.fixed_line | not) then "no Fixed Version: line"
               elif .trivy_image and .sev == "other" then "no readable severity"
               elif .kind == "image" and (.trivy | not) and (.osv | not) then "image category, unrecognised tool"
               elif .looks_image then "category names an image but not as <image>-<arch>"
               else null end)
      | .undecidable = (.why != null)
    )' "$tmp/cs.json" > "$tmp/norm.json"

# Dependabot: severity from the vulnerability, falling back to the advisory;
# `first_patched_version` null means no patched release exists yet -- the
# Dependabot spelling of "unfixed". An alert with no `security_vulnerability`
# object at all is undecidable, not unfixed.
jq '
  map(
    (.security_vulnerability // null) as $v
    | {
        number,
        url: (.html_url // ""),
        pkg: (.dependency.package.name // ""),
        eco: (.dependency.package.ecosystem // ""),
        manifest: (.dependency.manifest_path // ""),
        sev: (($v.severity // .security_advisory.severity // "") | ascii_downcase
              | if IN("critical", "high", "medium", "low") then . else "other" end),
        ghsa: (.security_advisory.ghsa_id // ""),
        cve: (.security_advisory.cve_id // ""),
        range: ($v.vulnerable_version_range // ""),
        patched: ($v.first_patched_version.identifier // ""),
        decidable: (($v | type) == "object")
      }
    | .gating = (.patched != "" and (.sev == "critical" or .sev == "high"))
  )' "$tmp/dep.json" > "$tmp/depnorm.json"

count() { jq "$1" "$tmp/norm.json"; }
dcount() { jq "$1" "$tmp/depnorm.json"; }
total=$(count 'length')
n_image=$(count 'map(select(.kind == "image")) | length')
n_stale=$(count 'map(select(.kind == "stale")) | length')
n_repo=$(count 'map(select(.kind == "repo")) | length')
n_fixable=$(count 'map(select(.gating)) | length')
n_excepted=$(count 'map(select(.excepted)) | length')
n_exc_expired=$(jq 'map(select(.active | not)) | length' "$tmp/exc.json")
n_undecided=$(count 'map(select(.undecidable)) | length')
d_total=$(dcount 'length')
d_fixable=$(dcount 'map(select(.gating)) | length')
d_undecided=$(dcount 'map(select(.decidable | not)) | length')

# Shared jq helpers for the sections: a Markdown-table-safe cell, a severity
# sort key, and a linked alert number.
readonly JQ_LIB='
  def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
  def sevrank: {"critical": 0, "high": 1, "medium": 2, "low": 3, "other": 4}[.] // 5;
  def link: if .url == "" then "#\(.number)" else "[#\(.number)](\(.url))" end;
'

# --- sections -----------------------------------------------------------------
#
# One file per section, concatenated at the end. The split is what lets the
# step summary carry as many whole leading sections as fit under its size
# limit when the full report does not.
#
# Sets $f to the next section's file. Not `f=$(section)`: a counter bumped
# inside a command substitution is bumped in a subshell and lost.
sec=0
section() { sec=$((sec + 1)); f=$(printf '%s/%02d.md' "$tmp" "$sec"); }

generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
repo_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-greenblacked/github-base-images}"

section
{
  echo "## Security alerts report"
  echo
  echo "Open alerts, generated $generated. Code scanning is read for \`refs/heads/main\`."
  echo "Sources: [code scanning]($repo_url/security/code-scanning), [Dependabot]($repo_url/security/dependabot)."
  echo
  echo "- **$total** open code-scanning alerts: **$n_image** in current images, **$n_stale** in stale categories, **$n_repo** repository-level."
  echo "- **$n_fixable** fixable HIGH/CRITICAL Trivy alerts in current images, not counting **$n_excepted** covered by an active exception."
  if [ "$n_exc_expired" -gt 0 ]; then
    echo "- **$n_exc_expired** expired entries in \`.github/vuln-exceptions.json\` to remove or renew."
  fi
  echo "- **$d_total** open Dependabot alerts, **$d_fixable** of them fixable HIGH/CRITICAL."
  echo "- GitHub secret-scanning alerts: **not read** (no token permission covers them; see below)."
  if [ $((n_undecided + d_undecided)) -gt 0 ]; then
    echo "- **$((n_undecided + d_undecided))** alerts whose fixability could not be read (see the last section)."
  fi
} > "$f"

section
cat > "$f" <<'EOF'

### How to read this

- **Unfixed** (no fixed version) is accepted risk waiting on upstream: there is no version to
  move to yet. The gate ignores these by design (`ignore-unfixed`); they are listed so the risk is
  visible, not because anything here is broken.
- **Fixable** means the advisory names a patched version. The vulnerability gate blocks a build
  that *adds* one of these (OS packages and libraries, HIGH/CRITICAL); one the published image
  already carries is **known upstream** and ships until upstream fixes it, so most of these are
  inherited from a runtime image or a package vendored inside another (pip's urllib3, npm's
  undici) with no release that fixes them yet. They close on their own when the daily rebuild or
  an automated bump picks up the fixed release. One that stays open after such a release exists
  is worth a look. A fixable HIGH/CRITICAL Dependabot alert is the same thing for the repository's
  own dependencies; Dependabot's pull request for it merges itself once green.
- **Excepted** alerts are fixable HIGH/CRITICAL findings where the fixed version exists in no
  released artifact yet (for example a module compiled into an upstream release binary), covered by
  an unexpired entry in `.github/vuln-exceptions.json`. The gate skips exactly these, per image, id
  and path or package version, until the entry expires; they are listed here so they stay visible,
  and do not fail the report. An expired entry excuses nothing.
- **Stale** categories belong to images no longer in `images.json`. Nothing uploads to them any
  more, so their alerts never close on their own.
- Code-scanning alerts reflect each category's **last upload**, not today's vulnerability
  database: an image's alerts change only when it is rebuilt and rescanned.
EOF

section
{
  echo
  echo "### Totals by tool and severity"
  echo
  echo "| tool | critical | high | medium | low | other | total |"
  echo "|---|---:|---:|---:|---:|---:|---:|"
  jq -r --slurpfile dep "$tmp/depnorm.json" "$JQ_LIB"'
    (map({tool, sev}) + ($dep[0] | map({tool: "Dependabot", sev})))
    | group_by(.tool)[]
    | (map(.sev) | group_by(.) | map({key: .[0], value: length}) | from_entries) as $c
    | "| \(.[0].tool | cell) | \($c.critical // 0) | \($c.high // 0) | \($c.medium // 0) | \($c.low // 0) | \($c.other // 0) | \(length) |"
  ' "$tmp/norm.json"
  if [ $((total + d_total)) -eq 0 ]; then
    echo "| _(none)_ | 0 | 0 | 0 | 0 | 0 | 0 |"
  fi
} > "$f"

section
{
  echo
  echo "### Per image"
  echo
  echo "Every image in \`images.json\`, including those with no alerts at all."
  echo
  echo "| image | Trivy critical | Trivy high | fixable H/C | excepted | OSV | archs with alerts |"
  echo "|---|---:|---:|---:|---:|---:|---|"
  jq -r --slurpfile images "$tmp/images.json" "$JQ_LIB"'
    . as $all
    | $images[0][] as $img
    | [ $all[] | select(.kind == "image" and .image == $img) ] as $a
    | ($a | map(select(.trivy_image))) as $t
    | "| \($img | cell) | \($t | map(select(.sev == "critical")) | length) | \($t | map(select(.sev == "high")) | length) | \($a | map(select(.gating)) | length) | \($a | map(select(.excepted)) | length) | \($a | map(select(.osv)) | length) | \($a | map(.arch) | unique | join(", ") | if . == "" then "—" else . end) |"
  ' "$tmp/norm.json"
} > "$f"

section
{
  echo
  echo "### Fixable HIGH/CRITICAL Trivy alerts"
  echo
  if [ "$n_fixable" -eq 0 ]; then
    echo "None."
  else
    echo "| image | arch | package | installed | fixed | CVE | severity | alert |"
    echo "|---|---|---|---|---|---|---|---|"
    jq -r "$JQ_LIB"'
      map(select(.gating))
      | sort_by(.image, .arch, (.sev | sevrank), .pkg, .rule)[]
      | "| \(.image | cell) | \(.arch | cell) | \(.pkg | cell) | \(.installed | cell) | \(.fixed | cell) | \(.rule | cell) | \(.sev) | \(link) |"
    ' "$tmp/norm.json"
  fi
} > "$f"

section
{
  echo
  echo "### Active exceptions"
  echo
  echo "Fixable HIGH/CRITICAL Trivy alerts covered by an unexpired entry in"
  echo "\`.github/vuln-exceptions.json\`. The gate does not fail on these until the entry expires, and"
  echo "neither does this report."
  echo
  if [ "$n_excepted" -eq 0 ]; then
    echo "None."
  else
    echo "| CVE | package | image | arch | installed | fixed | expires | reason | alert |"
    echo "|---|---|---|---|---|---|---|---|---|"
    jq -r "$JQ_LIB"'
      map(select(.excepted))
      | sort_by(.exception.expires, .image, .arch, .rule)[]
      | "| \(.rule | cell) | \(.pkg | cell) | \(.image | cell) | \(.arch | cell) | \(.installed | cell) | \(.fixed | cell) | \(.exception.expires | cell) | \(.exception.reason | cell) [upstream](\(.exception.upstream | cell)) | \(link) |"
    ' "$tmp/norm.json"
  fi
  if [ "$n_exc_expired" -gt 0 ]; then
    echo
    echo "#### Expired exceptions"
    echo
    echo "These entries no longer excuse anything, here or in the gate. Remove each one, or renew it"
    echo "with a new \`expires\` if its fix is still in no released artifact."
    echo
    echo "| CVE | package | image | expired | reason |"
    echo "|---|---|---|---|---|"
    jq -r "$JQ_LIB"'
      map(select(.active | not))
      | sort_by(.expires, .image, .id)[]
      | "| \(.id | cell) | \(.package | cell) | \(.image | cell) | \(.expires | cell) | \(.reason | cell) [upstream](\(.upstream | cell)) |"
    ' "$tmp/exc.json"
  fi
} > "$f"

section
{
  echo
  echo "### Dependabot alerts"
  echo
  if [ "$d_total" -eq 0 ]; then
    echo "None open."
  else
    echo "Every open alert, fixable HIGH/CRITICAL first. **fixable** marks the ones counted as fixable HIGH/CRITICAL."
    echo
    echo "| package | ecosystem | manifest | severity | advisory | vulnerable | first patched | fixable | alert |"
    echo "|---|---|---|---|---|---|---|---|---|"
    jq -r "$JQ_LIB"'
      sort_by((.gating | not), (.sev | sevrank), .pkg, .number)[]
      | "| \(.pkg | cell) | \(.eco | cell) | \(.manifest | cell) | \(.sev) | \([.ghsa, .cve] | map(select(. != "")) | join(" / ") | cell) | \(.range | cell) | \(if .patched == "" then "—" else (.patched | cell) end) | \(if .gating then "**fixable**" else "" end) | \(link) |"
    ' "$tmp/depnorm.json"
  fi
} > "$f"

section
{
  echo
  echo "### Secret scanning (GitHub)"
  echo
  echo "**Not checked by this report.** GitHub's secret-scanning alerts cannot be read with the"
  echo "workflow's \`GITHUB_TOKEN\` (no token permission grants that API), and this repository adds no"
  echo "personal access token or app credential to reach it. Review them by hand at"
  echo "[$repo_url/security/secret-scanning]($repo_url/security/secret-scanning)."
  echo
  echo "What does cover secrets in CI:"
  echo
  echo "- the Trivy secret gate on every image and architecture (\`build-image.yml\`), which fails the"
  echo "  build at any severity;"
  echo "- the Trivy filesystem secret scan of the working tree (\`security.yml\`), which gates, and whose"
  echo "  findings appear under repository-level alerts below as category \`repo-secrets\`;"
  echo "- the gitleaks scan of the full git history (\`security.yml\`), which reports to its job log and"
  echo "  artifact only, not to code scanning and not to this report."
} > "$f"

section
{
  echo
  echo "### Top $TOP_N CVEs / rule ids by images affected"
  echo
  echo "Current images only, Trivy and OSV together. A CVE across many images usually lives in a"
  echo "shared base (Debian, or a runtime's upstream image), so one upstream fix clears all of them."
  echo
  if [ "$n_image" -eq 0 ]; then
    echo "None."
  else
    echo "| rule | images | alerts | severity | fixable | images affected |"
    echo "|---|---:|---:|---|---|---|"
    jq -r --argjson top "$TOP_N" "$JQ_LIB"'
      map(select(.kind == "image"))
      | group_by(.rule)
      | map({
          rule: .[0].rule,
          images: (map(.image) | unique),
          alerts: length,
          sev: (map(.sev) | min_by(sevrank)),
          fixable: any(.[]; .fixable)
        })
      | sort_by(-(.images | length), -.alerts, .rule)[:$top][]
      | "| \(.rule | cell) | \(.images | length) | \(.alerts) | \(.sev) | \(if .fixable then "yes" else "no" end) | \(.images | join(", ") | cell) |"
    ' "$tmp/norm.json"
  fi
} > "$f"

section
{
  echo
  echo "### Repository-level alerts"
  echo
  echo "Code-scanning alerts not tied to an image: workflow audits, CodeQL, Scorecard, the"
  echo "repository secret scan."
  echo
  if [ "$n_repo" -eq 0 ]; then
    echo "None."
  else
    echo "| tool | rule | severity | alerts | categories | examples |"
    echo "|---|---|---|---:|---|---|"
    jq -r "$JQ_LIB"'
      map(select(.kind == "repo"))
      | group_by([.tool, .rule])
      | sort_by((map(.sev) | min_by(sevrank) | sevrank), .[0].tool, .[0].rule)[]
      | "| \(.[0].tool | cell) | \(.[0].rule | cell) | \(map(.sev) | min_by(sevrank)) | \(length) | \(map(.category) | unique | join(", ") | cell) | \(sort_by(.number)[:3] | map(link) | join(" ")) |"
    ' "$tmp/norm.json"
  fi
} > "$f"

section
{
  echo
  echo "### Stale categories"
  echo
  if [ "$n_stale" -eq 0 ]; then
    echo "None."
  else
    echo "These categories are named for images that are no longer in \`images.json\` (renamed or"
    echo "retired). Nothing will upload to them again, so their alerts stay open forever. Delete each"
    echo "category under **Security → Code scanning → Tool status**. They do not affect this report's"
    echo "exit code."
    echo
    echo "| category | tool | alerts |"
    echo "|---|---|---:|"
    jq -r "$JQ_LIB"'
      map(select(.kind == "stale"))
      | group_by(.category)[]
      | "| \(.[0].category | cell) | \(map(.tool) | unique | join(", ") | cell) | \(length) |"
    ' "$tmp/norm.json"
  fi
} > "$f"

if [ $((n_undecided + d_undecided)) -gt 0 ]; then
  section
  {
    echo
    echo "### Alerts whose fixability could not be read"
    echo
    echo "This report cannot say whether these should fail it: a Trivy message with no"
    echo "\`Fixed Version:\` line or no readable severity, an image category from a tool it does not"
    echo "recognise, a category that names an image but not in the \`<image>-<arch>\` form, or a"
    echo "Dependabot alert with no \`security_vulnerability\`. Most likely a format changed and"
    echo "\`scripts/alerts-report.sh\` needs updating. The run exits 1 rather than count these as clean."
    echo
    echo "| source | where | rule / package | severity | reason | alert |"
    echo "|---|---|---|---|---|---|"
    jq -r "$JQ_LIB"'
      map(select(.undecidable))
      | sort_by(.category, .rule)[]
      | "| \(.tool | cell) | \(.category | cell) | \(.rule | cell) | \(.sev) | \(.why) | \(link) |"
    ' "$tmp/norm.json"
    jq -r "$JQ_LIB"'
      map(select(.decidable | not))[]
      | "| Dependabot | \(.manifest | cell) | \(.pkg | cell) | \(.sev) | no security_vulnerability | \(link) |"
    ' "$tmp/depnorm.json"
  } > "$f"
fi

# --- write --------------------------------------------------------------------
#
# Assembled in the temp dir and moved into place in one step, so a report file
# at the destination is always a complete one.
cat "$tmp"/[0-9][0-9].md > "$tmp/report.md"
mv "$tmp/report.md" "$report_file"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ "$(wc -c < "$report_file")" -le "$SUMMARY_LIMIT" ]; then
    cp "$report_file" "$tmp/summary.md"
  else
    # Whole sections, in order, skipping any that would push the total over
    # the limit, then a note naming what was left out. Section order puts the
    # counts and the fixable lists first, so what gets skipped is the long
    # tail (usually repository-level alerts), not the part that explains a
    # red run -- and a small section after a skipped one still makes it in.
    : > "$tmp/summary.md"
    used=0
    omitted=""
    for s in "$tmp"/[0-9][0-9].md; do
      size=$(wc -c < "$s")
      if [ $((used + size)) -le "$SUMMARY_LIMIT" ]; then
        cat "$s" >> "$tmp/summary.md"
        used=$((used + size))
      else
        heading=$(grep -m1 '^###* ' "$s" || true)
        omitted="${omitted}${omitted:+, }${heading##*# }"
      fi
    done
    {
      echo
      echo "> **Truncated.** The full report is larger than the step summary allows. Left out here:"
      echo "> $omitted. The whole report is \`report.md\` in this run's \`code-scanning-report\` artifact."
    } >> "$tmp/summary.md"
  fi
  # A summary that cannot be written is a lost convenience, not a lost
  # report: report.md already exists, so this must not turn a finding (exit 3)
  # into an error (exit 1).
  cat "$tmp/summary.md" >> "$GITHUB_STEP_SUMMARY" \
    || printf 'warning: could not append to GITHUB_STEP_SUMMARY\n' >&2
fi

printf 'alerts-report: code scanning %d open (%d image, %d stale, %d repo-level), %d fixable HIGH/CRITICAL, %d excepted; Dependabot %d open, %d fixable HIGH/CRITICAL; %d undecidable; %d expired exceptions -> %s\n' \
  "$total" "$n_image" "$n_stale" "$n_repo" "$n_fixable" "$n_excepted" "$d_total" "$d_fixable" \
  "$((n_undecided + d_undecided))" "$n_exc_expired" "$report_file"

if [ $((n_fixable + d_fixable)) -gt 0 ]; then
  exit "$EXIT_FIXABLE"
fi
if [ $((n_undecided + d_undecided)) -gt 0 ]; then
  printf 'error: %d alert(s) whose fixability could not be read -- not a clean report\n' \
    "$((n_undecided + d_undecided))" >&2
  exit 1
fi
exit 0
