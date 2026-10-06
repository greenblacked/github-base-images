#!/usr/bin/env bash
# Offline tests for scripts/image-lifecycle.sh. No network: endoflife.date's
# v1 API, Docker Hub's tag API and MCR's tag list are answered from fixtures
# in their real shapes, and the script refuses to reach the network for a URL
# with no fixture. The `prs` cases push to a local bare repository with real
# git, answer the read-only gh queries from canned files and log every write
# through a fake gh.
#
#   ./scripts/test-image-lifecycle.sh    # run by scripts/lint.sh, so CI runs it too
#
# The tests run on a copy of this repository as it is, with the lifecycle
# state emptied and a fixed, synthetic "today" (TODAY below). Every version
# is derived from the copy -- the "next" Python line is the newest Python
# image's plus one minor, and so on -- so the tests keep passing as the real
# catalog moves on.
#
# SC2016 throughout: check strings and jq programs are single-quoted on purpose.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/.." && pwd)
lc="$here/image-lifecycle.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
# What a check prints is kept out of the way, and shown only when it fails.
check() {
  local what="$1"; shift
  if "$@" > "$work/check.log" 2>&1; then ok "$what"; else bad "$what"; sed 's/^/       | /' "$work/check.log" | head -20; fi
}

TODAY=2030-06-01
day() { jq -rn --arg d "$TODAY" --argjson n "$1" '$d + "T00:00:00Z" | fromdateiso8601 + $n * 86400 | strftime("%Y-%m-%d")'; }
unset GITHUB_ACTIONS GITHUB_STEP_SUMMARY DRY_RUN BASE_BRANCH LIFECYCLE_GH_STUB LIFECYCLE_RESULTS

# --- the base tree --------------------------------------------------------------
base="$work/base"; mkdir -p "$base"
(cd "$repo" && git ls-files -co --exclude-standard | tar cf - -T -) | tar xf - -C "$base"
echo '[]' > "$base/.github/lifecycle.json"
"$lc" render --root "$base"
"$lc" members --root "$base" > "$work/members.tsv"
new_tree() { rm -rf "${work:?}/$1"; cp -a "$base" "$work/$1"; printf '%s' "$work/$1"; }

# Per family: the newest and oldest image and cycle, and the next lines.
fam_newest() { awk -F'\t' -v f="$1" '$2 == f { c = $3 } END { print c }' "$work/members.tsv"; }
fam_oldest_img() { awk -F'\t' -v f="$1" '$2 == f { print $1; exit }' "$work/members.tsv"; }
fam_newest_img() { awk -F'\t' -v f="$1" '$2 == f { c = $1 } END { print c }' "$work/members.tsv"; }
minor_up() { printf '%s.%s' "${1%%.*}" "$(( ${1#*.} + 1 ))"; }
PY=$(minor_up "$(fam_newest python)");  PY_IMG="ci-python${PY//./}"
PHP=$(minor_up "$(fam_newest php)");    PHP_IMG="ci-php${PHP//./}"
RB=$(minor_up "$(fam_newest ruby)");    RB_IMG="ci-ruby${RB//./}"
NODE=$(( $(fam_newest node) + 2 ));     NODE_IMG="ci-node$NODE"
NODE_ODD=$(( $(fam_newest node) + 1 ))
JAVA=$(( $(fam_newest java) + 4 ));     JAVA_IMG="ci-java$JAVA"
JAVA_NONLTS=$(( $(fam_newest java) + 2 ))
NET=$(( $(fam_newest dotnet) + 1 ));    NET_IMG="ci-dotnet$NET"
OLD_NODE=$(fam_oldest_img node); OLD_NODE_CYC=$(awk -F'\t' -v i="$OLD_NODE" '$1 == i { print $3 }' "$work/members.tsv")
NEW_NODE=$(fam_newest_img node)
for v in PY PHP RB NODE JAVA NET OLD_NODE NEW_NODE; do [ -n "${!v}" ] || { echo "no $v in the tree" >&2; exit 1; }; done
[ "$OLD_NODE" != "$NEW_NODE" ] || { echo "these tests need two Node images" >&2; exit 1; }

# --- fixtures -------------------------------------------------------------------
# fixtures NAME -- a fresh fixture directory: every family's endoflife.date
# product lists one release per image in the tree, supported until 2040;
# Debian 13 (trixie) and Ubuntu 26.04 (resolute) are the newest released.
fixtures() {
  fx="$work/fx-$1"; rm -rf "$fx"; mkdir -p "$fx"; : > "$fx/urls"
  local fam product
  for fam in python node php ruby java dotnet; do
    case "$fam" in node) product=nodejs ;; java) product=eclipse-temurin ;; *) product=$fam ;; esac
    awk -F'\t' -v f="$fam" '$2 == f { print $3 }' "$work/members.tsv" \
      | jq -R --arg fam "$fam" '{name: ., codename: null, label: ., releaseDate: "2020-01-01",
             isLts: (if $fam == "dotnet" then (tonumber % 2 == 0) else true end), ltsFrom: "2020-01-01",
             isEoas: false, eoasFrom: null, isEol: false, eolFrom: "2040-12-31", isMaintained: true,
             latest: {name: (. + ".0"), date: "2020-01-01", link: null}}' | jq -s . > "$fx/rel-$product.json"
  done
  jq -n '[{name: "12", codename: "Bookworm", label: "12 (Bookworm)", releaseDate: "2023-06-10", isLts: false, eolFrom: "2028-06-30", isEol: false},
          {name: "13", codename: "Trixie", label: "13 (Trixie)", releaseDate: "2025-08-09", isLts: false, eolFrom: "2035-06-30", isEol: false},
          {name: "14", codename: "Forky", label: "14 (Forky)", releaseDate: "2099-01-01", isLts: false, eolFrom: null, isEol: false}]' > "$fx/rel-debian.json"
  jq -n '[{name: "24.04", codename: "Noble Numbat", label: "24.04 LTS", releaseDate: "2024-04-25", isLts: true, eolFrom: "2029-05-31", isEol: false},
          {name: "25.10", codename: "Questing Quokka", label: "25.10", releaseDate: "2025-10-09", isLts: false, eolFrom: "2026-07-01", isEol: true},
          {name: "26.04", codename: "Resolute Raccoon", label: "26.04 LTS", releaseDate: "2026-04-23", isLts: true, eolFrom: "2031-05-29", isEol: false},
          {name: "28.04", codename: "Something Else", label: "28.04 LTS", releaseDate: "2099-04-20", isLts: true, eolFrom: null, isEol: false}]' > "$fx/rel-ubuntu.json"
  echo '{"name": "dotnet/sdk", "tags": []}' > "$fx/mcr.json"
  printf '%s %s\n' "https://mcr.microsoft.com/v2/dotnet/sdk/tags/list" mcr.json >> "$fx/urls"
}
serve() { printf '%s %s\n' "$1" "$2" >> "$fx/urls"; }
# release PRODUCT JSON-OBJECT -- add (or replace by name) one release
release() {
  jq --argjson r "$2" 'map(select(.name != $r.name)) + [{codename: null, isLts: false, ltsFrom: null, isEol: false,
     eolFrom: "2040-12-31", latest: null, isMaintained: true} + $r]' "$fx/rel-$1.json" > "$fx/r.tmp" && mv "$fx/r.tmp" "$fx/rel-$1.json"
}
# set_rel PRODUCT NAME FIELD JSON-VALUE
set_rel() {
  jq --arg n "$2" --arg f "$3" --argjson v "$4" 'map(if .name == $n then .[$f] = $v else . end)' "$fx/rel-$1.json" \
    > "$fx/r.tmp" && mv "$fx/r.tmp" "$fx/rel-$1.json"
}
# Finalise: each product in the v1 API's wrapper, served at its URL, unless
# the case has already served that URL (an @fail, a malformed body).
publish_eol() {
  local f p url
  for f in "$fx"/rel-*.json; do
    p=${f##*/rel-}; p=${p%.json}; url="https://endoflife.date/api/v1/products/$p/"
    grep -q "^$url " "$fx/urls" && continue
    jq --arg p "$p" '{schema_version: "1.2.0", generated_at: "2030-06-01T00:00:00+00:00", last_modified: "2030-05-31T00:00:00+00:00",
       result: {name: $p, label: $p, category: "lang", releases: .}}' "$f" > "$fx/eol-$p.json"
    serve "$url" "eol-$p.json"
  done
}
# hub REPO TAG ARCH... -- Docker Hub's tag endpoint for an existing tag.
hub() {
  local repo_="$1" tag="$2" f; shift 2
  f="hub-$repo_-$tag.json"
  printf '%s\n' "$@" | jq -R '{architecture: ., os: "linux", status: "active"}' \
    | jq -s --arg t "$tag" '{name: $t, tag_status: "active", images: .}' > "$fx/$f"
  serve "https://hub.docker.com/v2/repositories/library/$repo_/tags/$tag" "$f"
}
hub404()  { serve "https://hub.docker.com/v2/repositories/library/$1/tags/$2" @404; }
hubfail() { serve "https://hub.docker.com/v2/repositories/library/$1/tags/$2" @fail; }
mcr_tags() { jq '.tags += $ARGS.positional' "$fx/mcr.json" --args "$@" < /dev/null > "$fx/m.tmp" && mv "$fx/m.tmp" "$fx/mcr.json"; }

# plan_run TREE -- sets rc, out (JSON lines), err.
plan_run() {
  publish_eol
  out="$work/plan.out"; err="$work/plan.err"; rc=0
  LIFECYCLE_FIXTURES="$fx" LIFECYCLE_TODAY="$TODAY" "$lc" plan --root "$1" > "$out" 2> "$err" || rc=$?
}
acts() { jq -r '.action + " " + .image' "$out" | sort | paste -sd, -; }
has_act() { jq -e --arg a "$1" --arg i "$2" 'select(.action == $a and .image == $i)' "$out" >/dev/null 2>&1; }
act_field() { jq -r --arg a "$1" --arg i "$2" --arg f "$3" 'select(.action == $a and .image == $i) | .[$f] | tostring' "$out"; }
warned() { grep -q "^warning: .*$1" "$err"; }
no_warnings() { ! grep -q '^warning:' "$err"; }
# state TREE JSON-ARRAY -- the lifecycle record, rendered into the docs.
state() { echo "$2" > "$1/.github/lifecycle.json"; "$lc" render --root "$1"; }
dep_entry() { # IMAGE EOL ANNOUNCED [STATE]
  jq -nc --arg i "$1" --arg e "$2" --arg a "$3" --arg s "${4:-deprecated}" --arg succ "$NEW_NODE" \
    '{image: $i, state: $s, runtime: "Node.js x", eol: $e, announced: $a, successor: $succ, notice: ("deprecated-" + $i)}'
}

# ================================================================================
echo "plan 1: nothing due"
t=$(new_tree p1); fixtures p1
plan_run "$t"
check "exit 0" [ "$rc" -eq 0 ]
check "no action" [ ! -s "$out" ]
check "no warning: go, rust and the tool images are never looked up" no_warnings
check "the exempt images are not family members" bash -c "! grep -qE '^ci-(go|rust|tools|cloud|security|db)	' '$work/members.tsv'"

echo "plan 2: a new Python line, GA on Docker Hub for both architectures -> added"
t=$(new_tree p2); fixtures p2
release python "{\"name\": \"$PY\", \"releaseDate\": \"$(day -30)\"}"
hub python "$PY-slim-trixie" amd64 arm64 arm 386
plan_run "$t"
check "exit 0, no warning" bash -c "[ $rc -eq 0 ] && ! grep -q '^warning:' '$err'"
check "add $PY_IMG" [ "$(acts)" = "add $PY_IMG" ]
check "  on python:$PY-slim-trixie (the newest Debian stable)" [ "$(act_field add "$PY_IMG" upstream)" = "python:$PY-slim-trixie" ]
check "  keyed by its upstream" [ "$(act_field add "$PY_IMG" key)" = "python:$PY-slim-trixie" ]

echo "plan 3: only a release candidate tag -> not added, silently"
t=$(new_tree p3); fixtures p3
release python "{\"name\": \"$PY\", \"releaseDate\": \"$(day -30)\"}"
hub404 python "$PY-slim-trixie"
plan_run "$t"
check "no action" [ ! -s "$out" ]
check "no warning: not yet is not a problem" no_warnings
check "the log says it is not published yet" grep -q "python:$PY-slim-trixie is not published" "$err"
check "  and a notice says the line is waiting for that tag, so the wait is visible" \
  grep -q "^notice: python $PY is released and supported upstream, but not yet published as python:$PY-slim-trixie for both" "$err"

echo "plan 4: the tag exists for amd64 only -> not added"
t=$(new_tree p4); fixtures p4
release python "{\"name\": \"$PY\", \"releaseDate\": \"$(day -30)\"}"
hub python "$PY-slim-trixie" amd64
plan_run "$t"
check "no action" [ ! -s "$out" ]
check "the log says why" grep -q 'not for both linux/amd64 and linux/arm64' "$err"

echo "plan 5: a line endoflife.date lists before its release date -> not added, not even probed"
t=$(new_tree p5); fixtures p5
release python "{\"name\": \"$PY\", \"releaseDate\": \"$(day 10)\"}"
plan_run "$t"
check "no action, and no warning (a probe would have hit a URL with no fixture)" bash -c "[ ! -s '$out' ] && ! grep -q '^warning:' '$err'"

echo "plan 6: a registry error is a warning, never an add"
t=$(new_tree p6); fixtures p6
release python "{\"name\": \"$PY\", \"releaseDate\": \"$(day -30)\"}"
hubfail python "$PY-slim-trixie"
plan_run "$t"
check "exit 0, no action" bash -c "[ $rc -eq 0 ] && [ ! -s '$out' ]"
check "a warning names the tag" warned "did not answer for python:$PY-slim-trixie"

echo "plan 7: Node.js -- even majors once LTS; odd majors never"
t=$(new_tree p7); fixtures p7
release nodejs "{\"name\": \"$NODE\", \"releaseDate\": \"$(day -150)\", \"ltsFrom\": \"$(day 1)\"}"
release nodejs "{\"name\": \"$NODE_ODD\", \"releaseDate\": \"$(day -200)\"}"
hub node "$NODE-trixie-slim" amd64 arm64
plan_run "$t"
check "the day before its LTS date: not added" [ ! -s "$out" ]
check "  and nothing probed for the odd major" no_warnings
set_rel nodejs "$NODE" ltsFrom "\"$TODAY\""
sed -i.bak '/endoflife.date/d' "$fx/urls"
plan_run "$t"
check "on its LTS date: add $NODE_IMG" [ "$(acts)" = "add $NODE_IMG" ]
check "  on node:$NODE-trixie-slim" [ "$(act_field add "$NODE_IMG" upstream)" = "node:$NODE-trixie-slim" ]

echo "plan 8: Java -- LTS only, on the newest Ubuntu LTS when Temurin has no Debian tag"
t=$(new_tree p8); fixtures p8
release eclipse-temurin "{\"name\": \"$JAVA_NONLTS\", \"releaseDate\": \"$(day -60)\", \"isLts\": false}"
plan_run "$t"
check "a non-LTS release: not added" [ ! -s "$out" ]
release eclipse-temurin "{\"name\": \"$JAVA\", \"releaseDate\": \"$(day -20)\", \"isLts\": true}"
hub404 eclipse-temurin "$JAVA-jdk-trixie"
hub eclipse-temurin "$JAVA-jdk-resolute" amd64 arm64 ppc64le s390x
sed -i.bak '/endoflife.date/d' "$fx/urls"
plan_run "$t"
check "an LTS release: add $JAVA_IMG" [ "$(acts)" = "add $JAVA_IMG" ]
check "  on eclipse-temurin:$JAVA-jdk-resolute" [ "$(act_field add "$JAVA_IMG" upstream)" = "eclipse-temurin:$JAVA-jdk-resolute" ]
check "  codename resolute, so the line is resolute-v1" [ "$(act_field add "$JAVA_IMG" codename)" = resolute ]
check "  only the two probes it needed (28.04 is not released yet, 25.10 is not LTS)" bash -c "! grep -q 'no fixture' '$err'"
check "  and no waiting notice once it is added" bash -c "! grep -q '^notice:' '$err'"

echo "plan 9: an error on the Debian probe stops there -- Ubuntu is not tried on a guess"
t=$(new_tree p9); fixtures p9
release eclipse-temurin "{\"name\": \"$JAVA\", \"releaseDate\": \"$(day -20)\", \"isLts\": true}"
hubfail eclipse-temurin "$JAVA-jdk-trixie"
plan_run "$t"
check "no action" [ ! -s "$out" ]
check "a warning names the tag" warned "did not answer for eclipse-temurin:$JAVA-jdk-trixie"
check "resolute was not probed (it has no fixture, so a probe would say so)" bash -c "! grep -q 'no fixture' '$err'"

echo "plan 10: .NET -- MCR's floating tag exists from the first preview; only a GA SDK tag counts"
t=$(new_tree p10); fixtures p10
release dotnet "{\"name\": \"$NET\", \"releaseDate\": \"$(day -5)\", \"isLts\": false}"
mcr_tags "$NET.0-resolute" "$NET.0-resolute-amd64" "$NET.0-resolute-arm64v8" "$NET.0.100-rc.2-resolute" "$NET.0.100-preview.7-resolute"
plan_run "$t"
check "RC: not added" [ ! -s "$out" ]
check "  with no warning" no_warnings
check "  but a notice naming both tags it looked for (newest Debian, then newest Ubuntu LTS)" \
  grep -q "^notice: dotnet $NET .* not yet published as mcr.microsoft.com/dotnet/sdk:$NET.0-trixie-slim or mcr.microsoft.com/dotnet/sdk:$NET.0-resolute for" "$err"
mcr_tags "$NET.0.100-resolute"
plan_run "$t"
check "GA: add $NET_IMG" [ "$(acts)" = "add $NET_IMG" ]
check "  on mcr.microsoft.com/dotnet/sdk:$NET.0-resolute (no trixie-slim tag)" \
  [ "$(act_field add "$NET_IMG" upstream)" = "mcr.microsoft.com/dotnet/sdk:$NET.0-resolute" ]
check "  STS" [ "$(act_field add "$NET_IMG" lts)" = false ]
jq '.tags |= map(select(. != "'"$NET"'.0-resolute-arm64v8"))' "$fx/mcr.json" > "$fx/m" && mv "$fx/m" "$fx/mcr.json"
plan_run "$t"
check "no arm64 tag: not added" [ ! -s "$out" ]

echo "plan 11: deprecation from 120 days before end of support"
t=$(new_tree p11); fixtures p11
set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day 121)\""
plan_run "$t"
check "121 days before: nothing" [ ! -s "$out" ]
set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day 120)\""
sed -i.bak '/endoflife.date/d' "$fx/urls"
plan_run "$t"
check "120 days before: deprecate $OLD_NODE" [ "$(acts)" = "deprecate $OLD_NODE" ]
check "  with its end of support" [ "$(act_field deprecate "$OLD_NODE" eol)" = "$(day 120)" ]
check "  and the newest Node image as the successor" [ "$(act_field deprecate "$OLD_NODE" successor)" = "$NEW_NODE" ]

echo "plan 12: an announced deprecation is not announced again; a moved date is"
state "$t" "[$(dep_entry "$OLD_NODE" "$(day 120)" "$(day -3)")]"
plan_run "$t"
check "same date on record: nothing" [ ! -s "$out" ]
state "$t" "[$(dep_entry "$OLD_NODE" "$(day 100)" "$(day -3)")]"
plan_run "$t"
check "a different date on record: deprecate again" [ "$(acts)" = "deprecate $OLD_NODE" ]
check "  saying what it was" [ "$(act_field deprecate "$OLD_NODE" previous_eol)" = "$(day 100)" ]

echo "plan 13: retirement after end of support, 30 days after the notice at the earliest"
t=$(new_tree p13); fixtures p13
set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$TODAY\""
state "$t" "[$(dep_entry "$OLD_NODE" "$TODAY" "$(day -90)")]"
plan_run "$t"
check "on the end-of-support date: nothing" [ ! -s "$out" ]
set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day -1)\""
sed -i.bak '/endoflife.date/d' "$fx/urls"
state "$t" "[$(dep_entry "$OLD_NODE" "$(day -1)" "$(day -30)")]"
plan_run "$t"
check "the day after, announced 30 days ago: retire $OLD_NODE" [ "$(acts)" = "retire $OLD_NODE" ]
state "$t" "[$(dep_entry "$OLD_NODE" "$(day -1)" "$(day -29)")]"
plan_run "$t"
check "announced 29 days ago: not yet" [ ! -s "$out" ]
check "  and the log says when" grep -q "retired once that is 30 days old" "$err"
state "$t" '[]'
plan_run "$t"
check "past end of support but never announced: announced first, not retired" [ "$(acts)" = "deprecate $OLD_NODE" ]
for bad_record in 'del(.announced)' '.announced = ""' '.announced = "2030-13-45"' '.announced = "soon"' '.eol = ""'; do
  # Written straight into the file, as a hand edit or a bad merge would: render
  # would not even run on some of these.
  dep_entry "$OLD_NODE" "$(day -1)" "$(day -60)" | jq -s "map($bad_record)" > "$t/.github/lifecycle.json"
  plan_run "$t"
  check "a record with $bad_record: no retirement, no re-announcement" [ ! -s "$out" ]
  check "  and a warning that names the image" warned "$OLD_NODE: .github/lifecycle.json has no valid announced/eol date"
done

echo "plan 14: endoflife.date unreachable or unreadable -> warnings, never an add or a retirement"
t=$(new_tree p14); fixtures p14
release python "{\"name\": \"$PY\", \"releaseDate\": \"$(day -30)\"}"
hub python "$PY-slim-trixie" amd64 arm64
serve "https://endoflife.date/api/v1/products/python/" @fail
set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day -1)\""
state "$t" "[$(dep_entry "$OLD_NODE" "$(day -1)" "$(day -60)")]"
plan_run "$t"
check "python unreachable: no add, and a warning naming it" bash -c "! grep -q '\"add\"' '$out' && grep -q '^warning: python: endoflife.date' '$err'"
check "  the other families still work: retire $OLD_NODE" has_act retire "$OLD_NODE"
t=$(new_tree p14b); fixtures p14b
release python "{\"name\": \"$PY\", \"releaseDate\": \"$(day -30)\"}"
hub python "$PY-slim-trixie" amd64 arm64
serve "https://endoflife.date/api/v1/products/debian/" @fail
plan_run "$t"
check "Debian's releases unreachable: no add (the distribution cannot be chosen)" [ ! -s "$out" ]
check "  a warning says so" warned "endoflife.date (debian) could not be read"
t=$(new_tree p14c); fixtures p14c
for p in python nodejs php ruby eclipse-temurin dotnet debian ubuntu; do serve "https://endoflife.date/api/v1/products/$p/" @fail; done
set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day -1)\""
state "$t" "[$(dep_entry "$OLD_NODE" "$(day -1)" "$(day -60)")]"
plan_run "$t"
check "all unreachable: exit 0, no action at all" bash -c "[ $rc -eq 0 ] && [ ! -s '$out' ]"
check "  one warning per family" [ "$(grep -c '^warning: .*could not be read; no add, deprecation or retirement' "$err")" -eq 6 ]
t=$(new_tree p14d); fixtures p14d
# The v0 API's shape (a bare array), or an error page: unreadable, not "no releases".
echo '[{"cycle": "3.14", "eol": "2030-10-31"}]' > "$fx/v0.json"
serve "https://endoflife.date/api/v1/products/python/" v0.json
plan_run "$t"
check "an answer in another shape is unreadable: a warning" warned "python: endoflife.date"

# ================================================================================
echo "apply 1: a scaffold per family -- lints, parses, and changes only what it must"
t=$(new_tree a1)
scaffold() { # IMAGE UPSTREAM LTS
  LIFECYCLE_TODAY="$TODAY" "$lc" apply add --image "$1" --upstream "$2" --lts "$3" --root "$t" > "$work/a.out" 2> "$work/a.err"
}
for spec in "$PY_IMG python:$PY-slim-trixie false" "$PHP_IMG php:$PHP-cli-trixie false" \
            "$RB_IMG ruby:$RB-slim-trixie false" "$NODE_IMG node:$NODE-trixie-slim true" \
            "$JAVA_IMG eclipse-temurin:$JAVA-jdk-resolute true" "$NET_IMG mcr.microsoft.com/dotnet/sdk:$NET.0-resolute false"; do
  # shellcheck disable=SC2086  # three words
  set -- $spec
  rc=0; scaffold "$1" "$2" "$3" || rc=$?
  check "$1: added" [ "$rc" -eq 0 ]
  check "  ARG BASE_IMAGE=$2" grep -qxF "ARG BASE_IMAGE=$2" "$t/$1/Dockerfile.ci"
  check "  test.sh executable and parses" bash -c "[ -x '$t/$1/test.sh' ] && bash -n '$t/$1/test.sh'"
  if command -v shellcheck >/dev/null; then check "  shellcheck clean" shellcheck "$t/$1/test.sh"; fi
  check "  images.json entry" jq -e --arg i "$1" --arg u "$2" 'any(.[]; .image == $i and .upstream == $u)' "$t/.github/images.json"
  check "  Dependabot entry" grep -qxF "    directory: /$1" "$t/.github/dependabot.yml"
  check "  catalog row" grep -qF "| [\`$1\`](docs/images.md#" "$t/README.md"
  check "  docs bullet" grep -qF -- "- **\`$1\`**" "$t/docs/images.md"
done
check "the tree passes the lifecycle check" "$lc" check --root "$t"
check "the README count is the new total" grep -q "There are $(jq length "$t/.github/images.json"):" "$t/README.md"
check "the version lines: trixie-v1 for Debian, resolute-v1 for Ubuntu 26.04" \
  bash -c "jq -e '[.[] | select(.image == \"$PY_IMG\" or .image == \"$NODE_IMG\") | .version] == [\"trixie-v1\", \"trixie-v1\"]
           and ([.[] | select(.image == \"$JAVA_IMG\" or .image == \"$NET_IMG\") | .version] | sort == [\"resolute-v1\", \"resolute-v1\"])' '$t/.github/images.json' >/dev/null"
check "mirrors reuse the runtime's mirror package" \
  bash -c "jq -e '[.[] | select(.image == \"$JAVA_IMG\")][0].mirror == \"mirror-temurin:$JAVA-jdk-resolute\"' '$t/.github/images.json' >/dev/null"
check "python: the version assertion is the new line's" grep -qF "= $PY ]'" "$t/$PY_IMG/test.sh"
check "php: lower and upper bound" grep -qF "version_compare(PHP_VERSION, \\\"$PHP\\\", \\\">=\\\") && version_compare(PHP_VERSION, \\\"${PHP%%.*}.$(( ${PHP#*.} + 1 ))\\\"" "$t/$PHP_IMG/test.sh"
check "java: the version assertion" grep -qF "grep -qE \" ${JAVA}[. ]\"" "$t/$JAVA_IMG/test.sh"
check ".NET: both assertions" [ "$(grep -c "\"^$NET\\\\.\"" "$t/$NET_IMG/test.sh")" -eq 2 ]
check "ruby: copied from a sibling without a line-specific workaround" \
  bash -c "[ ! -e '$t/$RB_IMG/replace-default-gem.rb' ] && ! grep -q '^ARG JSON_VERSION=' '$t/$RB_IMG/Dockerfile.ci'"
check "node: the shared pins came along" bash -c "grep -q '^ARG NPM_VERSION=' '$t/$NODE_IMG/Dockerfile.ci' && grep -q '^ARG PLAYWRIGHT_VERSION=' '$t/$NODE_IMG/Dockerfile.ci'"
check "node: the distribution-aware Playwright check is copied as is" \
  [ "$(grep '"playwright libs present"' "$t/$NODE_IMG/test.sh")" = "$(grep '"playwright libs present"' "$t/$NEW_NODE/test.sh")" ]
check "the diff from each sibling is only the version, base, label and assertion lines (and comments)" bash -c "
  for p in '$PY_IMG:python' '$PHP_IMG:php' '$NODE_IMG:node' '$JAVA_IMG:java' '$NET_IMG:dotnet'; do
    img=\${p%%:*}; sib=\$(awk -F'\t' -v f=\${p#*:} '\$2 == f { c = \$1 } END { print c }' '$work/members.tsv')
    diff '$t/'\$sib/Dockerfile.ci '$t/'\$img/Dockerfile.ci | grep '^>' | grep -vE '^> (#|ARG BASE_IMAGE=|LABEL org.opencontainers.image.description=)' && exit 1
    diff '$t/'\$sib/test.sh '$t/'\$img/test.sh | grep '^>' | grep -vE '^> (#|check \")' && exit 1
  done; exit 0"

echo "apply 2: the lifecycle check catches every way the files can disagree"
broken() { # NAME -- a fresh tree to break; sets t
  t=$(new_tree "b-$1")
}
fails_check() { local rc=0; "$lc" check --root "$t" > /dev/null 2> "$work/check.err" || rc=$?; [ "$rc" -eq 3 ] && grep -q "$1" "$work/check.err"; }
broken dep; awk -v d="    directory: /$OLD_NODE" '$0 == d { print "    directory: /ci-nosuch"; next } { print }' "$t/.github/dependabot.yml" > "$t/x" && mv "$t/x" "$t/.github/dependabot.yml"
check "a Dependabot directory that is not an image" fails_check "dependabot.yml docker directories differ"
broken dep2; sed -i.bak "/directory: \/$OLD_NODE\$/{n;n;s/daily/weekly/;}" "$t/.github/dependabot.yml"
check "a Dependabot entry that is not the standard one" fails_check "is not the standard docker entry"
broken base; sed -i.bak 's/^ARG BASE_IMAGE=.*/ARG BASE_IMAGE=node:0-bookworm-slim/' "$t/$OLD_NODE/Dockerfile.ci"
check "an ARG BASE_IMAGE default that is not images.json's upstream" fails_check "$OLD_NODE/Dockerfile.ci: ARG BASE_IMAGE=node:0-bookworm-slim"
broken row; grep -v "^| \[\`$OLD_NODE\`\]" "$t/README.md" > "$t/x" && mv "$t/x" "$t/README.md"
check "a missing catalog row" fails_check "README.md catalog rows differ"
broken tag; sed -i.bak "/^| \[\`$OLD_NODE\`\]/s/-v1\` |\$/-v2\` |/" "$t/README.md"
check "a catalog row with the wrong tag" fails_check "the $OLD_NODE row does not show"
broken count; sed -i.bak 's/There are [0-9]*:/There are 99:/' "$t/README.md"
check "a wrong count" fails_check 'does not say'
broken bullet; awk -v b="- **\`$OLD_NODE\`**" 'index($0, b) == 1 { skip = 1; next } skip && /^  / { next } { skip = 0; print }' "$t/docs/images.md" > "$t/x" && mv "$t/x" "$t/docs/images.md"
check "a missing docs bullet" fails_check "docs/images.md image bullets differ"
broken marker; sed -i.bak "/^| \[\`$OLD_NODE\`\]/s/) | /) **(deprecated: retires after 2031-01-01)** | /" "$t/README.md"
check "a deprecation marker by hand, with no record" fails_check "not what .github/lifecycle.json says"
broken ghost; echo "[$(dep_entry ci-node1 2031-01-01 2030-01-01)]" > "$t/.github/lifecycle.json"
check "a record of an image that is not in images.json" fails_check "ci-node1 is deprecated but not in images.json"
broken stalestate; state "$t" "[$(dep_entry "$OLD_NODE" "$(day 10)" "$(day -1)")]"
jq '.[0].eol = "2031-02-02"' "$t/.github/lifecycle.json" > "$t/x" && mv "$t/x" "$t/.github/lifecycle.json"
check "notices not regenerated after the record changed" fails_check "not what .github/lifecycle.json says"
broken mirror; jq --arg i "$OLD_NODE" 'map(if .image == $i then .mirror = "mirror-node:0-x" else . end)' "$t/.github/images.json" > "$t/x" && mv "$t/x" "$t/.github/images.json"
check "a mirror that does not carry the upstream tag" fails_check "does not carry the upstream tag"
t=$(new_tree clean)
check "and the unbroken tree passes" "$lc" check --root "$t"
cp -a "$t" "$work/clean.snap"; "$lc" render --root "$t"
check "render twice changes nothing" diff -r "$t" "$work/clean.snap"

echo "apply 3: deprecate, then retire"
t=$(new_tree a3)
jq --arg i "$OLD_NODE" --arg e "$(day 40)" '. + [{image: $i, id: "CVE-2030-0001", package: "x", installed: "1", reason: "r",
   upstream: "u", expires: $e, purls: ["pkg:npm/x@1"]}]' "$t/.github/vuln-exceptions.json" > "$t/x" && mv "$t/x" "$t/.github/vuln-exceptions.json"
rc=0; LIFECYCLE_TODAY="$(day -60)" "$lc" apply deprecate --image "$OLD_NODE" --eol "$(day -1)" --root "$t" 2>/dev/null || rc=$?
check "deprecate: exit 0" [ "$rc" -eq 0 ]
check "  recorded, with the successor and the announcement date" \
  jq -e --arg i "$OLD_NODE" --arg s "$NEW_NODE" --arg a "$(day -60)" 'any(.[]; .image == $i and .state == "deprecated" and .successor == $s and .announced == $a)' "$t/.github/lifecycle.json"
check "  the catalog row is marked with the date" grep -qF "| [\`$OLD_NODE\`](docs/images.md#nodejs) **(deprecated: retires after $(day -1))** |" "$t/README.md"
check "  README, SECURITY.md and docs/images.md carry the notice" \
  bash -c "grep -q 'Deprecated: \`$OLD_NODE\`' '$t/README.md' && grep -q '\`$OLD_NODE\` is deprecated' '$t/SECURITY.md' && grep -q '^### Deprecated: \`$OLD_NODE\`' '$t/docs/images.md'"
check "  the tree passes the check" "$lc" check --root "$t"
rc=0; LIFECYCLE_TODAY="$TODAY" "$lc" apply retire --image "$NEW_NODE" --root "$t" 2>/dev/null || rc=$?
check "retiring an image that was never deprecated is refused" [ "$rc" -eq 2 ]
rc=0; LIFECYCLE_TODAY="$TODAY" "$lc" apply retire --image "$OLD_NODE" --root "$t" 2>/dev/null || rc=$?
check "retire: exit 0" [ "$rc" -eq 0 ]
check "  the directory is gone" [ ! -e "$t/$OLD_NODE" ]
check "  and its images.json, Dependabot and vulnerability-exception entries" \
  bash -c "! grep -q '\"$OLD_NODE\"' '$t/.github/images.json' '$t/.github/vuln-exceptions.json' && ! grep -q '/$OLD_NODE\$' '$t/.github/dependabot.yml'"
check "  and its catalog row and bullet" bash -c "! grep -q '\`$OLD_NODE\`\](docs' '$t/README.md' && ! grep -qF -- '- **\`$OLD_NODE\`**' '$t/docs/images.md'"
check "  the notice is gone from README and SECURITY.md" bash -c "! grep -q 'Deprecated: \`$OLD_NODE\`' '$t/README.md' && ! grep -q '$OLD_NODE\` is deprecated' '$t/SECURITY.md'"
check "  docs/images.md keeps a Retired note, under the old anchor" \
  bash -c "grep -qx '<a id=\"deprecated-$OLD_NODE\"></a>' '$t/docs/images.md' && grep -q '^### Retired: \`$OLD_NODE\`' '$t/docs/images.md'"
check "  usage examples that pulled it now pull the successor" \
  bash -c "! grep -rq 'ghcr.io/greenblacked/${OLD_NODE}[:@]' '$t/README.md' '$t/docs/images.md' '$t/docs/pipeline.md' '$t/docs/security.md'"
check "  the tree passes the check" "$lc" check --root "$t"
# Where a YAML parser is at hand (a runner usually has one), the edited
# Dependabot file still parses.
if python3 -c 'import yaml' 2>/dev/null; then
  check "  Dependabot's file still parses as YAML" python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$t/.github/dependabot.yml"
fi

# ================================================================================
# prs: real git against a local bare origin, a fake gh.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
prev=""
for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$FAKE_GH_LOG.body"; prev="$a"; done
if [ -n "${FAKE_GH_FAIL:-}" ] && printf '%s\n' "$*" | grep -qE "$FAKE_GH_FAIL"; then
  echo "gh (fake): refused: $*" >&2; exit 1
fi
if [ "$1 $2" = "pr create" ]; then echo "https://github.com/o/r/pull/$((500 + $(grep -c '^pr create' "$FAKE_GH_LOG")))"; fi
exit 0
EOF
chmod +x "$work/bin/gh"
BOT='41898282+github-actions[bot]@users.noreply.github.com'
CHECKS_ALL='{"total_count":4,"check_runs":[{"name":"CI result","conclusion":"success"},
  {"name":"Repository secret scan","conclusion":"success"},{"name":"CodeQL (workflows)","conclusion":"success"},
  {"name":"Dependency review","conclusion":"success"}]}'

# scenario NAME -- origin with main at the base tree (optionally changed by
# a function given as $2 before the commit), a clone to run in, a stub dir.
scenario() {
  local src="$work/src-$1"
  d="$work/prs-$1"; rm -rf "$d" "$src"; mkdir -p "$d/stub"
  cp -a "$base" "$src"
  if [ -n "${2:-}" ]; then "$2" "$src"; fi
  git -C "$src" init -q -b main
  git -C "$src" add -A
  git -C "$src" -c user.name=base -c user.email=base@example.com commit -qm base
  git clone -q --bare "$src" "$d/origin.git"
  git clone -q "$d/origin.git" "$d/clone"
  origin="$d/origin.git"; stub="$d/stub"; log="$d/gh.log"; : > "$log"
}
run_prs() {
  publish_eol
  out="$d/out"; res="$d/results.jsonl"; rc=0
  (cd "$d/clone" && PATH="$work/bin:$PATH" GITHUB_REPOSITORY=o/r LIFECYCLE_GH_STUB="$stub" LIFECYCLE_RESULTS="$res" \
     LIFECYCLE_FIXTURES="$fx" LIFECYCLE_TODAY="$TODAY" FAKE_GH_LOG="$log" "$lc" prs) > "$out" 2>&1 || rc=$?
}
rrow() { jq -r --arg i "$1" --arg f "$2" 'select(.image == $i) | .[$f]' "$res"; }
logged()     { grep -qxF -- "$1" "$log"; }
not_logged() { ! grep -qE -- "$1" "$log"; }
head_of()    { git -C "$origin" rev-parse -q --verify "refs/heads/$1" || true; }
main_sha()   { git -C "$origin" rev-parse refs/heads/main; }
# pr_stub BRANCH NUMBER STATE KEY ACTION IMAGE
# pr_stub BRANCH NUMBER STATE KEY ACTION IMAGE [LABELS-JSON] -- without
# LABELS-JSON the answer carries no labels field at all (unknown labels).
pr_stub() {
  jq -n --arg b "$1" --argjson n "$2" --arg s "$3" --arg k "$4" --arg a "$5" --arg i "$6" --argjson l "${7:-null}" \
    '[{number: $n, state: $s, url: ("https://github.com/o/r/pull/" + ($n | tostring)), headRefName: $b, isCrossRepository: false,
       body: ("text\n<!-- image-lifecycle: action=" + $a + " image=" + $i + " key=" + $k + " -->")}
      + (if $l == null then {} else {labels: $l} end)]' > "$stub/pr-${1//\//_}.json"
}
# open_pr NUMBER BRANCH [LOGIN] -- one more open PR in `GET pulls?state=open`.
open_pr() {
  [ -f "$stub/open-prs.json" ] || echo '[]' > "$stub/open-prs.json"
  jq --argjson n "$1" --arg r "$2" --arg u "${3:-github-actions[bot]}" \
    '. + [{number: $n, user: {login: $u}, head: {ref: $r, repo: {full_name: "o/r"}}}]' "$stub/open-prs.json" > "$stub/o.tmp" && mv "$stub/o.tmp" "$stub/open-prs.json"
}
# seed_branch BRANCH AUTHOR-EMAIL -- a one-commit branch on origin.
seed_branch() {
  local s="$d/seed-${1//\//_}"
  rm -rf "${s:?}"; git clone -q "$origin" "$s"
  echo "# seeded" >> "$s/README.md"
  git -C "$s" -c user.name=x -c user.email="$2" commit -qam seed
  git -C "$s" push -q origin "HEAD:refs/heads/$1"
}
py_ga() { release python "{\"name\": \"$PY\", \"releaseDate\": \"$(day -30)\"}"; hub python "$PY-slim-trixie" amd64 arm64; }
BR="lifecycle/add-$PY_IMG"

echo "prs 1: a new line -> one branch, one bot commit, one PR, CI dispatched"
fixtures r1; py_ga; scenario r1
run_prs
check "exit 0" [ "$rc" -eq 0 ]
check "result ok, with the PR" [ "$(rrow "$PY_IMG" status):$(rrow "$PY_IMG" pr)" = "ok:https://github.com/o/r/pull/501" ]
check "$BR is one commit on main" [ "$(git -C "$origin" rev-parse "$BR^")" = "$(main_sha)" ]
check "  authored and committed by the bot" [ "$(git -C "$origin" log -1 --format='%ae %ce' "$BR")" = "$BOT $BOT" ]
check "  it adds the image" bash -c "git -C '$origin' show '$BR:$PY_IMG/Dockerfile.ci' | grep -qx 'ARG BASE_IMAGE=python:$PY-slim-trixie'"
check "  and touches nothing under .github/workflows/" bash -c "! git -C '$origin' diff --name-only main '$BR' | grep -q '^.github/workflows/'"
check "  test.sh is committed executable" [ "$(git -C "$origin" ls-tree "$BR" "$PY_IMG/test.sh" | cut -c1-6)" = 100755 ]
rm -rf "$d/branch"; mkdir "$d/branch"; git -C "$origin" archive "$BR" | tar xf - -C "$d/branch"
check "  the branch passes the lifecycle check" "$lc" check --root "$d/branch"
check "PR created" grep -q "^pr create --repo o/r --base main --head $BR --title Add $PY_IMG: Python $PY on Debian Trixie" "$log"
check "Build and Push dispatched on the branch" logged "workflow run build-and-push.yml --repo o/r --ref $BR"
check "Security dispatched on the branch" logged "workflow run security.yml --repo o/r --ref $BR"
check "nothing merged here" not_logged '^pr merge'
check "the body names the one manual step: making the package public" grep -q 'make.*public\|Change visibility' "$log.body"
check "the body says it merges itself, and how to stop it" grep -q 'Add the `hold` label to stop it' "$log.body"
check "the body records the action for the next run" grep -qxF "<!-- image-lifecycle: action=add image=$PY_IMG key=python:$PY-slim-trixie -->" "$log.body"

echo "prs 2: re-run, PR open at the same change, CI never reported -> dispatched again, nothing pushed"
sha=$(head_of "$BR")
pr_stub "$BR" 501 OPEN "python:$PY-slim-trixie" add "$PY_IMG"
echo '{"total_count":0,"check_runs":[]}' > "$stub/checks-${BR//\//_}.json"
: > "$log"; run_prs
check "exit 0" [ "$rc" -eq 0 ]
check "unchanged" [ "$(rrow "$PY_IMG" status)" = unchanged ]
check "both workflows dispatched again" bash -c "grep -qx 'workflow run build-and-push.yml --repo o/r --ref $BR' '$log' && grep -qx 'workflow run security.yml --repo o/r --ref $BR' '$log'"
check "the branch was not pushed" [ "$(head_of "$BR")" = "$sha" ]
check "the PR was not edited or created" not_logged '^pr (edit|create)'

echo "prs 3: re-run, CI present -> nothing written at all"
printf '%s' "$CHECKS_ALL" > "$stub/checks-${BR//\//_}.json"
: > "$log"; run_prs
check "exit 0, unchanged" [ "$rc:$(rrow "$PY_IMG" status)" = "0:unchanged" ]
check "no gh write" not_logged '.'
check "branch untouched" [ "$(head_of "$BR")" = "$sha" ]

echo "prs 4: main moved under an open PR -> rebuilt on the new main, PR updated"
s="$d/mover"; rm -rf "$s"; git clone -q "$origin" "$s"
echo "# moved" >> "$s/README.md"; git -C "$s" -c user.name=m -c user.email=m@example.com commit -qam moved; git -C "$s" push -q origin HEAD:main
: > "$log"; run_prs
check "exit 0" [ "$rc" -eq 0 ]
check "rebuilt: one commit on the new main" [ "$(git -C "$origin" rev-parse "$BR^")" = "$(main_sha)" ]
check "PR edited, not created" bash -c "grep -q '^pr edit 501 ' '$log' && ! grep -q '^pr create' '$log'"
check "CI dispatched" logged "workflow run build-and-push.yml --repo o/r --ref $BR"

echo "prs 5: someone else committed to the branch -> left alone"
s="$d/human"; rm -rf "$s"; git clone -q "$origin" "$s"; git -C "$s" checkout -q "$BR"
echo "# mine" >> "$s/README.md"; git -C "$s" -c user.name=h -c user.email=h@example.com commit -qam mine; git -C "$s" push -q origin "HEAD:$BR"
sha=$(head_of "$BR"); : > "$log"; run_prs
check "exit 0, skipped" [ "$rc:$(rrow "$PY_IMG" status)" = "0:skipped" ]
check "  the note names them" bash -c "jq -r 'select(.image == \"$PY_IMG\") | .note' '$res' | grep -q h@example.com"
check "  no write, branch untouched" bash -c "[ ! -s '$log' ] && [ '$(head_of "$BR")' = '$sha' ]"

echo "prs 6: closed unmerged for the same change -> not reopened"
fixtures r6; py_ga; scenario r6
pr_stub "$BR" 77 CLOSED "python:$PY-slim-trixie" add "$PY_IMG"
run_prs
check "exit 0, skipped" [ "$rc:$(rrow "$PY_IMG" status)" = "0:skipped" ]
check "  no branch, no write" bash -c "[ -z '$(head_of "$BR")' ] && [ ! -s '$log' ]"
fixtures r6b; py_ga; scenario r6b
pr_stub "$BR" 78 CLOSED "python:$PY-slim-trixie" add "$PY_IMG" '[{"name": "something-else"}]'
run_prs
check "closed by a person (no superseded label): still a veto" [ "$rc:$(rrow "$PY_IMG" status)" = "0:skipped" ]
fixtures r6c; py_ga; scenario r6c
pr_stub "$BR" 79 CLOSED "python:$PY-slim-trixie" add "$PY_IMG" '[{"name": "lifecycle-superseded"}]'
run_prs
check "closed by this workflow as no longer due: not a veto, a fresh PR opens" [ "$rc:$(rrow "$PY_IMG" status)" = "0:ok" ]
check "  created, not reopened" bash -c "grep -q '^pr create .* --head $BR ' '$log' && ! grep -q '^pr reopen' '$log'"

echo "prs 7: deprecate, then retire, through pull requests"
with_eol_state() { echo "[$(dep_entry "$OLD_NODE" "$(day -1)" "$(day -60)")]" > "$1/.github/lifecycle.json"; "$lc" render --root "$1"; }
fixtures r7; set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day 30)\""; scenario r7
run_prs
DB="lifecycle/deprecate-$OLD_NODE"
check "deprecate: exit 0, ok" [ "$rc:$(rrow "$OLD_NODE" status)" = "0:ok" ]
check "  the change is docs and the record only, so CI builds nothing" \
  [ "$(git -C "$origin" diff --name-only main "$DB" | paste -sd' ' -)" = ".github/lifecycle.json README.md SECURITY.md docs/images.md" ]
check "  the title says when" grep -q "^pr create .* --title Deprecate $OLD_NODE: Node.js $OLD_NODE_CYC reaches end of support on $(day 30)" "$log"
fixtures r7b; set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day -1)\""; scenario r7b with_eol_state
run_prs
RB_="lifecycle/retire-$OLD_NODE"
check "retire: exit 0, ok" [ "$rc:$(rrow "$OLD_NODE" status)" = "0:ok" ]
rm -rf "$d/branch"; mkdir "$d/branch"; git -C "$origin" archive "$RB_" | tar xf - -C "$d/branch"
check "  the directory is removed on the branch" [ ! -e "$d/branch/$OLD_NODE" ]
check "  and the branch passes the lifecycle check" "$lc" check --root "$d/branch"
check "  the body tells the owner about the package" grep -q 'Delete this package' "$log.body"

echo "prs 8: endoflife.date unreachable -> exit 0, warnings in the summary, nothing written"
fixtures r8; for p in python nodejs php ruby eclipse-temurin dotnet debian ubuntu; do serve "https://endoflife.date/api/v1/products/$p/" @fail; done
scenario r8
run_prs
check "exit 0" [ "$rc" -eq 0 ]
check "no gh write, no branch" bash -c "[ ! -s '$log' ] && [ -z \"\$(git -C '$origin' for-each-ref refs/heads/lifecycle)\" ]"
check "the summary lists the warnings" grep -q '^Warnings (no action was taken on anything they affect):' "$out"

echo "prs 9: a failed dispatch is an error, after everything else was done"
fixtures r9; py_ga; scenario r9
FAKE_GH_FAIL='^workflow run security\.yml' run_prs
check "exit 1" [ "$rc" -eq 1 ]
check "  the row is an error naming the dispatch" bash -c "jq -r 'select(.image == \"$PY_IMG\") | .status + \" \" + .note' '$res' | grep -q '^error gh workflow run security.yml failed'"
check "  Build and Push was still dispatched" logged "workflow run build-and-push.yml --repo o/r --ref $BR"

echo "prs 10: a GA line still waiting for its tag is a notice in the run, every day it waits"
fixtures r10; release python "{\"name\": \"$PY\", \"releaseDate\": \"$(day -30)\"}"; hub404 python "$PY-slim-trixie"
scenario r10
GITHUB_ACTIONS=true run_prs
check "exit 0, nothing written" bash -c "[ $rc -eq 0 ] && [ ! -s '$log' ]"
check "a ::notice:: annotation names the line and the tag" grep -q "^::notice::python $PY is released and supported upstream, but not yet published as python:$PY-slim-trixie" "$out"
check "the summary lists it under waiting" grep -q '^Waiting for an upstream tag (checked again tomorrow):' "$out"
check "  and it is not a warning" bash -c "! grep -q '^::warning::' '$out'"

echo "prs 11: an open lifecycle PR that is no longer due is closed, labelled, its branch deleted"
# main records ci-<old node> deprecated, and a retirement PR is open for it;
# then upstream moved its end of support 200 days out.
moved() { echo "[$(dep_entry "$OLD_NODE" "$(day -1)" "$(day -60)")]" > "$1/.github/lifecycle.json"; "$lc" render --root "$1"; }
RT="lifecycle/retire-$OLD_NODE"
fixtures r11; set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day 200)\""; scenario r11 moved
seed_branch "$RT" "$BOT"; open_pr 600 "$RT"
echo '[{"name":"lifecycle-superseded"}]' > "$stub/labels.json"
run_prs
check "exit 0" [ "$rc" -eq 0 ]
check "the date correction is today's plan: a deprecation PR" bash -c "grep -q '^pr create .* --head lifecycle/deprecate-$OLD_NODE ' '$log'"
check "the stale retirement is labelled first" logged "pr edit 600 --repo o/r --add-label lifecycle-superseded"
check "  then closed with a comment, and its branch deleted" grep -q "^pr close 600 --repo o/r --comment No longer due as of $TODAY: today's plan has \`deprecate\` for \`$OLD_NODE\` instead (end of support $(day 200)).* --delete-branch\$" "$log"
check "  label before close" bash -c "[ \$(grep -n '^pr edit 600 ' '$log' | cut -d: -f1) -lt \$(grep -n '^pr close 600 ' '$log' | cut -d: -f1) ]"
check "  and the summary row says so" [ "$(jq -r 'select(.pr == "#600") | .status' "$res")" = closed ]
echo "prs 12: an outage never closes anything"
fixtures r12; set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day 200)\""; serve "https://endoflife.date/api/v1/products/nodejs/" @fail
scenario r12 moved
seed_branch "$RT" "$BOT"; open_pr 601 "$RT"
run_prs
check "exit 0, and no gh write at all" bash -c "[ $rc -eq 0 ] && [ ! -s '$log' ]"
check "  the branch is still there" [ -n "$(head_of "$RT")" ]
echo "prs 13: a stale PR someone else committed to is left open, with a warning"
fixtures r13; set_rel nodejs "$OLD_NODE_CYC" eolFrom "\"$(day 200)\""; scenario r13 moved
seed_branch "$RT" human@example.com; open_pr 602 "$RT"
run_prs
check "exit 0, not closed" bash -c "[ $rc -eq 0 ] && ! grep -q '^pr \(close\|edit\) 602 ' '$log'"
check "  a warning names it" grep -q "#602 ($RT) is no longer due, but it has commits not made by this workflow (human@example.com)" "$out"
echo "prs 14: what is still due, and what is not ours, stays open"
fixtures r14; py_ga; scenario r14
open_pr 603 "$BR"                                         # due today: handled by the add, not closed
open_pr 604 "lifecycle/retire-ci-go"                      # not a family this script manages
open_pr 605 "lifecycle/retire-$OLD_NODE" someone          # a person's branch of that name
run_prs
check "exit 0" [ "$rc" -eq 0 ]
check "none of them closed" not_logged '^pr close'
check "  the unmanaged one is a warning" grep -q '#604 (lifecycle/retire-ci-go): not a lifecycle change this script makes' "$out"

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
