#!/usr/bin/env bash
# Drop the OpenSSF Scorecard findings this repository accepts by design from
# the SARIF that goes to code scanning, and keep everything else.
#
#   ./scripts/filter-scorecard-sarif.sh scorecard.sarif scorecard-upload.sarif
#   ./scripts/filter-scorecard-sarif.sh --check          # validate the list only
#
# Options (before the operands):
#   --accepted FILE  the accepted list (default: .github/scorecard-accepted.json)
#   --root DIR       the checkout the SARIF paths are relative to (default: the
#                    repository this script is in)
#
# Exit 0 when OUT was written, 1 when it could not be trusted to be (a
# malformed list or SARIF, or anything unexpected), 2 on usage. OUT is
# removed first and written only on success, so a failed run leaves nothing
# that could be uploaded as if it were the filtered result. security.yml then
# uploads the UNFILTERED SARIF: a failure shows every alert, it never hides
# one.
#
# Why (docs/adr/0003, amendment of 2026-10-14)
# --------------------------------------------
# Code scanning shows what someone can act on. Scorecard reports a fixed set
# of checks, several of which this repository fails by design: every
# Dockerfile builds FROM a base passed in as a tag (the verified mirror on
# main, rebuilt daily -- docs/adr/0001, 0007, 0008), npm is pinned by version
# rather than hash, there is one maintainer, nothing to fuzz. Those alerts
# never close, and they sat beside the two that do need someone (branch
# protection, which is the owner's setting, and Maintained, which clears once
# the repository is 90 days old). The full Scorecard result is still the
# `scorecard-results` artifact, unfiltered.
#
# The accepted list
# -----------------
# .github/scorecard-accepted.json, an array of entries, each one of:
#
#   {"rule": "CodeReviewID", "reason": "..."}
#       rule-wide: every result of that rule is dropped.
#   {"rule": "PinnedDependenciesID", "path": "^ci-[a-z0-9]+/Dockerfile\\.ci$",
#    "match": "^FROM \\$\\{BASE_IMAGE\\}\\s*$", "reason": "..."}
#       a result of that rule is dropped only if EVERY location it has is a
#       file whose path matches `path` and whose flagged line (the SARIF
#       region.startLine, read from the checkout) matches `match`.
#
# `path` and `match` are jq (Oniguruma) regular expressions; `path` must be
# anchored at both ends. Every entry needs a non-empty `reason`, and any key
# other than these four is an error, so a typo cannot quietly widen or
# disable an entry.
#
# Matching the line rather than the file is the point: a new unpinned
# `RUN pip install foo` in a Dockerfile whose FROM line is accepted is still
# reported. A result whose location cannot be resolved -- no locations, a
# path that is absolute, has `..`, or is not a file in the checkout, a line
# past the end -- is kept, unless a rule-wide entry covers its rule. So is
# one whose line no longer matches because the tree moved under Scorecard:
# the failure direction is always "shown".
#
# Every decision is printed: dropped (rule, path:line, reason) and kept
# (rule, path:line), then any entry that matched nothing -- most likely one
# that can be deleted.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
accepted=""
check_only=0

usage() {
  echo "usage: $0 [--accepted FILE] [--root DIR] IN.sarif OUT.sarif" >&2
  echo "       $0 [--accepted FILE] --check" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --accepted) [ $# -ge 2 ] || usage; accepted="$2"; shift 2 ;;
    --root)     [ $# -ge 2 ] || usage; root="$2"; shift 2 ;;
    --check)    check_only=1; shift ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ -n "$accepted" ] || accepted="$root/.github/scorecard-accepted.json"

if [ "$check_only" -eq 1 ]; then
  [ $# -eq 0 ] || usage
else
  [ $# -eq 2 ] || usage
  in="$1" out="$2"
  # Before anything can fail: a stale OUT from an earlier run must not be
  # mistaken for this run's result.
  rm -f -- "$out"
fi

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq not found"
[ -f "$accepted" ] || die "accepted list $accepted not found"

# --- The accepted list. Every problem is listed, not just the first.
if ! problems=$(jq -r '
    def text: type == "string" and length > 0;
    def compiles: . as $re | (try ("" | test($re) | true) catch false);
    if type != "array" then "not a JSON array"
    else
      to_entries[]
      | .key as $n | .value as $e
      | "entry \($n) (\($e.rule? // "?"))" as $at
      | if ($e | type) != "object" then "\($at): not an object"
        else
          ( $e | keys[] | select(IN("rule", "path", "match", "reason") | not)
            | "\($at): unknown key \(tojson) (allowed: rule, path, match, reason)" ),
          ( select(($e.rule | text) | not) | "\($at): missing or empty \"rule\"" ),
          ( select(($e.rule | text) and ($e.rule | test("^[A-Za-z]+ID$") | not))
            | "\($at): rule \($e.rule | tojson) is not a Scorecard rule id (e.g. PinnedDependenciesID)" ),
          ( select(($e.reason | text) | not) | "\($at): missing or empty \"reason\"" ),
          ( select(($e | has("path")) != ($e | has("match")))
            | "\($at): \"path\" and \"match\" go together; leave both out for a rule-wide entry" ),
          ( ("path", "match") as $k
            | select($e | has($k))
            | if ($e[$k] | text) | not then "\($at): \($k) must be a non-empty string"
              elif ($e[$k] | compiles) | not then "\($at): \($k) \($e[$k] | tojson) is not a valid regular expression"
              else empty end ),
          ( select(($e.path | text) and (($e.path | startswith("^") and endswith("$")) | not))
            | "\($at): path \($e.path | tojson) must be anchored with ^ and $" )
        end
    end' "$accepted"); then
  die "$accepted is not valid JSON"
fi
if [ -n "$problems" ]; then
  while IFS= read -r line; do printf 'error: %s: %s\n' "$accepted" "$line" >&2; done <<< "$problems"
  exit 1
fi

if [ "$check_only" -eq 1 ]; then
  echo "$accepted: $(jq length "$accepted") accepted entr(ies) checked"
  exit 0
fi

# --- The SARIF: the shape this script relies on, checked up front.
[ -f "$in" ] || die "$in not found"
if ! jq -e '
    (.runs | type == "array" and length > 0)
    and all(.runs[]; (.results | type == "array")
      and all(.results[]; type == "object"
        and (.ruleId | type == "string" and length > 0)
        and ((has("locations") | not) or (.locations | type == "array"))))
    ' "$in" >/dev/null 2>&1; then
  die "$in is not a SARIF log this script understands (runs[].results[].ruleId, locations[])"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- The lines to read: every location of every result that a path entry
# --- for its rule could cover and no rule-wide entry already does.
jq -r --slurpfile acc "$accepted" '
    ($acc[0]) as $acc
    | .runs[].results[]
    | .ruleId as $r
    | select(any($acc[]; .rule == $r and (has("path") | not)) | not)
    | (.locations // [])[]
    | .physicalLocation.artifactLocation.uri as $u
    | .physicalLocation.region.startLine as $l
    | select(($u | type) == "string" and ($l | type) == "number")
    | select(any($acc[]; . as $e | $e.rule == $r and ($e | has("path")) and ($u | test($e.path))))
    | "\($u)\t\($l)"
  ' "$in" | sort -u > "$work/wanted.tsv"

# Read each one from the checkout. A location that does not resolve to a line
# of a file inside the checkout is simply left out, so nothing can match it.
: > "$work/lines.jsonl"
while IFS=$'\t' read -r uri line; do
  [ -n "$uri" ] || continue
  case "$uri" in
    /*|..|../*|*/..|*/../*) continue ;;
  esac
  [[ "$uri" =~ ^[A-Za-z0-9._/+-]+$ ]] || continue
  [[ "$line" =~ ^[1-9][0-9]{0,6}$ ]] || continue
  f="$root/$uri"
  [ -f "$f" ] || continue
  if text=$(awk -v n="$line" 'NR == n { sub(/\r$/, ""); print; found = 1; exit } END { exit !found }' "$f"); then
    jq -cn --arg k "$uri:$line" --arg v "$text" '{key: $k, value: $v}' >> "$work/lines.jsonl"
  fi
done < "$work/wanted.tsv"
jq -s 'from_entries' "$work/lines.jsonl" > "$work/lines.json"

# --- Decide. Each result is kept or dropped as a whole; the run, its tool
# --- and rules are copied unchanged, so the category keeps its shape.
jq --slurpfile acc "$accepted" --slurpfile lines "$work/lines.json" '
    ($acc[0] | to_entries | map(.value + {n: .key})) as $acc
    | ($lines[0]) as $lines
    | def where: if (.physicalLocation.artifactLocation.uri | type) == "string"
                 then "\(.physicalLocation.artifactLocation.uri):\(.physicalLocation.region.startLine // "?")"
                 else "(no location)" end;
      def cover($r):
        .physicalLocation.artifactLocation.uri as $u
        | $lines["\($u):\(.physicalLocation.region.startLine)"] as $t
        | if ($u | type) != "string" or $t == null then null
          else first($acc[] | . as $e
                     | select($e.rule == $r and ($e | has("path"))
                              and ($u | test($e.path)) and ($t | test($e.match))))
               // null
          end;
      def decide:
        .ruleId as $r
        | (.locations // []) as $locs
        | (if ($locs | length) == 0 then ["(no location)"] else [$locs[] | where] end) as $at
        | (first($acc[] | select(.rule == $r and (has("path") | not))) // null) as $wide
        | if $wide != null then {drop: true, rule: $r, at: $at, by: [$wide]}
          elif ($locs | length) == 0 then {drop: false, rule: $r, at: $at}
          else ([$locs[] | cover($r)]) as $c
            | if all($c[]; . != null) then {drop: true, rule: $r, at: $at, by: ($c | unique_by(.n))}
              else {drop: false, rule: $r, at: $at} end
          end;
      [.runs[].results[] | decide] as $d
    | {
        sarif: (.runs |= map(.results |= map(select(decide | .drop | not)))),
        decisions: $d,
        unused: [$acc[] | .n as $n | select(any($d[]; .drop and any(.by[]; .n == $n)) | not)]
      }
  ' "$in" > "$work/result.json"

jq '.sarif' "$work/result.json" > "$work/out.sarif"

# Self-check before anything is written: what was kept plus what was dropped
# is what came in, and every drop names the entry that allowed it.
total=$(jq '[.runs[].results | length] | add' "$in")
kept=$(jq '[.runs[].results | length] | add' "$work/out.sarif")
dropped=$(jq '[.decisions[] | select(.drop)] | length' "$work/result.json")
[ "$((kept + dropped))" -eq "$total" ] || die "internal: kept $kept + dropped $dropped != $total results in"
jq -e 'all(.decisions[] | select(.drop); (.by | length) > 0)' "$work/result.json" >/dev/null \
  || die "internal: a dropped result names no accepted entry"

echo "Scorecard SARIF $in: $total result(s), $dropped dropped as accepted ($accepted), $kept kept for code scanning"
jq -r '
    .decisions[] | select(.drop)
    | "  dropped  \(.rule)  \(.at | join(", "))  -- \(.by | map(.reason) | join(" / "))"
  ' "$work/result.json"
jq -r '
    .decisions[] | select(.drop | not)
    | "  kept     \(.rule)  \(.at | join(", "))"
  ' "$work/result.json"
jq -r '
    .unused[]
    | "  note: accepted entry \(.n) (\(.rule)\(if has("path") then " \(.path)" else "" end)) matched no result -- delete it if the finding is gone for good"
  ' "$work/result.json"

mv "$work/out.sarif" "$out"
