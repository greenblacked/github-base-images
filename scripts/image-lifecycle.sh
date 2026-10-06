#!/usr/bin/env bash
# The image lifecycle: add an image when upstream ships a new supported line,
# announce its deprecation before upstream end of support, and retire it
# after -- the script behind .github/workflows/image-lifecycle.yml
# (docs/adr/0009-image-lifecycle.md, which amends docs/adr/0005).
#
#   ./scripts/image-lifecycle.sh plan              # what is due today, as JSON lines; changes nothing
#   ./scripts/image-lifecycle.sh prs               # one pull request per due action (the workflow)
#   ./scripts/image-lifecycle.sh apply add --image ci-python315 --upstream python:3.15-slim-trixie
#   ./scripts/image-lifecycle.sh apply deprecate --image ci-node22 --eol 2027-04-30
#   ./scripts/image-lifecycle.sh apply retire --image ci-dotnet8
#   ./scripts/image-lifecycle.sh render            # regenerate the lifecycle parts of the docs
#   ./scripts/image-lifecycle.sh check             # the consistency checks scripts/lint.sh gates on
#   ./scripts/image-lifecycle.sh members           # managed images: image, family, cycle, codename, ...
#
# Every subcommand takes --root DIR (default: this repository).
#
# What is managed. The versioned runtime images, one per upstream support
# line: Python, Node.js, PHP, Ruby, Java (Temurin) and .NET. The FAMILIES
# table below maps each to its endoflife.date product and its upstream tag
# shapes; an image belongs to a family when its name is ci-<family><digits>
# and its images.json `upstream` has one of those shapes. Everything else is
# exempt and never touched: ci-go and ci-rust track a floating `1-<codename>`
# tag (current stable, no lines), and the tool images have no runtime.
#
# The rules (docs/adr/0009-image-lifecycle.md has the why):
#   add        a cycle newer than the family's newest image, GA (released, and
#              the exact tag exists upstream for linux/amd64 and linux/arm64),
#              not end-of-life; Node.js only even majors once their LTS date
#              has passed; Java only LTS. Never an older line (no backfill).
#              Distribution: the newest Debian stable whose exact tag exists,
#              else the newest Ubuntu LTS (for the families that publish one).
#              Version line `<codename>-v1`.
#   deprecate  from 120 days before upstream end of support (endoflife.date's
#              eolFrom: the end of security fixes). Recorded in
#              .github/lifecycle.json, which is what makes it idempotent.
#   retire     after end of support, once the deprecation has been on main for
#              at least 30 days. The directory, its images.json, dependabot
#              and vulnerability-exception entries go; the docs keep a
#              "Retired" note, and every anchor that linked to the notice.
# Anything not known -- endoflife.date unreachable, a registry that errored
# rather than answered "no such tag" -- means no action for what depended on
# it and a warning. Never an add or a retirement on a guess.
#
# `prs` turns each action into a pull request on lifecycle/<action>-<image>,
# the way scripts/pin-bump-prs.sh does for pins: rebuilt from main, one commit
# by github-actions[bot], pushed with a lease, CI dispatched on the branch,
# healed on a re-run, never pushed over a commit someone else made, never
# reopened once closed. merge-bot-prs.sh merges it when green. It never
# touches .github/workflows/.
#
# Environment:
#   GITHUB_REPOSITORY  owner/repo (prs)
#   GH_TOKEN           for gh, and git push via a credential helper (prs)
#   BASE_BRANCH        default main
#   DRY_RUN=1          prs: make the branches locally, print every push, PR
#                      write and dispatch instead of making it
#   RUN_URL            linked from each PR body
#   LIFECYCLE_TODAY    YYYY-MM-DD, default today (UTC)
#   LIFECYCLE_FIXTURES directory whose `urls` file answers every HTTP request
#                      ("<url> <file>", "<url> @404" or "<url> @fail"); a URL
#                      not listed fails rather than reaching the network
#   LIFECYCLE_GH_STUB  directory of canned answers for the read-only gh
#                      queries (pr-<branch with / as _>.json, checks-<...>.json)
#   LIFECYCLE_RESULTS  prs: also write the per-action results here (JSON lines)
#
# Exit: 0 done (warnings included), 1 an action failed, 2 usage or a broken
# tree, 3 check found inconsistencies.
#
# SC2016 throughout: jq programs handed to json_write, and Markdown backticks
# in printf formats, are single-quoted on purpose.
# shellcheck disable=SC2016
set -euo pipefail

readonly NOTICE_DAYS=120
readonly MIN_NOTICE_DAYS=30
readonly OWNER_REF=ghcr.io/greenblacked
readonly BOT_NAME='github-actions[bot]'
readonly BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
readonly CHECK_WORKFLOWS=("CI result|build-and-push.yml" "Repository secret scan|security.yml"
  "CodeQL (workflows)|security.yml" "Dependency review|security.yml")

# family | endoflife.date product | cycle regex | distributions tried, in order |
# Debian tag | Ubuntu tag      ({v} the cycle, {c} the codename)
readonly FAMILIES='
python | python          | [0-9]+\.[0-9]+ | debian        | python:{v}-slim-{c}                         | -
node   | nodejs          | [0-9]+         | debian        | node:{v}-{c}-slim                           | -
php    | php             | [0-9]+\.[0-9]+ | debian        | php:{v}-cli-{c}                             | -
ruby   | ruby            | [0-9]+\.[0-9]+ | debian        | ruby:{v}-slim-{c}                           | -
java   | eclipse-temurin | [0-9]+         | debian ubuntu | eclipse-temurin:{v}-jdk-{c}                 | eclipse-temurin:{v}-jdk-{c}
dotnet | dotnet          | [0-9]+         | debian ubuntu | mcr.microsoft.com/dotnet/sdk:{v}.0-{c}-slim | mcr.microsoft.com/dotnet/sdk:{v}.0-{c}
'
# Debian's codenames (Toy Story); any other codename is Ubuntu's.
readonly DEBIAN_CODENAMES=' buzz rex bo hamm slink potato woody sarge etch lenny squeeze wheezy jessie stretch buster bullseye bookworm trixie forky duke '

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/.." && pwd)
today=${LIFECYCLE_TODAY:-$(date -u +%Y-%m-%d)}
fixtures=${LIFECYCLE_FIXTURES:-}
base=${BASE_BRANCH:-main}
dry=${DRY_RUN:-}
stub=${LIFECYCLE_GH_STUB:-}
repo=${GITHUB_REPOSITORY:-}

log()  { printf '%s\n' "$*" >&2; }
die()  { log "error: $*"; exit 2; }
warn() {
  log "warning: $*"
  [ -z "${WARNINGS:-}" ] || printf '%s\n' "$*" >> "$WARNINGS"
}
# Not a problem, but not silent either: a GA line waiting for its upstream
# tag. Listed in the run summary and as a ::notice:: each day it waits.
notice() {
  log "notice: $*"
  [ -z "${NOTICES:-}" ] || printf '%s\n' "$*" >> "$NOTICES"
}

# --- small helpers -------------------------------------------------------------
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
# A real calendar date in YYYY-MM-DD (2030-13-45 is not one).
is_date() {
  printf '%s' "$1" | grep -qxE '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    && [ "$(jq -rn --arg d "$1" 'try ($d + "T00:00:00Z" | fromdateiso8601 | strftime("%Y-%m-%d")) catch ""')" = "$1" ]
}
date_add() { jq -rn --arg d "$1" --argjson n "$2" '$d + "T00:00:00Z" | fromdateiso8601 + $n * 86400 | strftime("%Y-%m-%d")'; }
# 0 when version $1 sorts strictly after $2.
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
cap() { printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"; }
distro_of() { case "$DEBIAN_CODENAMES" in *" $1 "*) echo Debian ;; *) echo Ubuntu ;; esac; }
# "a", "a and b", "a, b and c"
join_and() {
  local n=$# out="" i=0 x
  for x in "$@"; do
    i=$((i + 1))
    if [ "$i" -eq 1 ]; then out=$x
    elif [ "$i" -eq "$n" ]; then out="$out and $x"
    else out="$out, $x"; fi
  done
  printf '%s' "$out"
}
# Markdown paragraph wrapping at 100 columns; continuation lines get $2.
wrap() { local p="${1:-}"; fold -s -w "$(( ${2:-99} - ${#p} ))" | sed 's/[[:space:]]*$//' | sed "2,\$s/^/$p/"; }

fam_field() { # FAMILY N
  local line
  line=$(printf '%s\n' "$FAMILIES" | awk -F'|' -v f="$1" '{ x=$1; gsub(/[[:space:]]/, "", x); if (x == f) { print; exit } }')
  [ -n "$line" ] || return 1
  trim "$(printf '%s' "$line" | cut -d'|' -f"$2")"
}
families() { printf '%s\n' "$FAMILIES" | awk -F'|' 'NF > 1 { x=$1; gsub(/[[:space:]]/, "", x); print x }'; }
# The ERE an upstream of this template matches: \1 the cycle, \2 the codename.
tmpl_re() { # TEMPLATE CYCLE-RE
  local t
  t=$(printf '%s' "$1" | sed 's/[.]/\\./g')
  t=${t//\{v\}/($2)}; t=${t//\{c\}/([a-z]+)}
  printf '^%s$' "$t"
}
tmpl_fill() { local t="$1"; t=${t//\{v\}/$2}; printf '%s' "${t//\{c\}/$3}"; }

# Family membership of every image in IMAGES-JSON: one TSV line per member,
# image, family, cycle, codename, upstream, version line, mirror. Sorted by
# family, then cycle ascending.
members() { # IMAGES-JSON
  local fam vre t1 t2 r
  for fam in $(families); do
    vre=$(fam_field "$fam" 3); t1=$(fam_field "$fam" 5); t2=$(fam_field "$fam" 6)
    for r in "$(tmpl_re "$t1" "$vre")" "$( [ "$t2" = - ] || tmpl_re "$t2" "$vre")"; do
      [ -n "$r" ] || continue
      jq -r --arg f "$fam" --arg re "$r" '
        .[] | select(.image | test("^ci-" + $f + "[0-9]+$"))
        | (.upstream | [match($re).captures[].string]) as $m
        | select($m | length == 2)
        | [.image, $f, $m[0], $m[1], .upstream, .version, .mirror] | @tsv' "$1"
    done
  done | sort -u | sort -t$'\t' -k2,2 -k3,3V
}
image_name() { printf 'ci-%s%s' "$1" "${2//./}"; } # FAMILY CYCLE

# --- text: one place for every sentence that names a runtime ---------------------
runtime() { # FAMILY CYCLE -- for "X reaches end of support"
  case "$1" in
    python) echo "Python $2" ;; node) echo "Node.js $2" ;; php) echo "PHP $2" ;;
    ruby) echo "Ruby $2" ;; java) echo "Java $2" ;; dotnet) echo ".NET $2" ;;
  esac
}
contents() { # FAMILY CYCLE LTS -- the catalog's "What's in it"
  case "$1" in
    python) echo "Python $2, pip" ;;
    node)   echo "Node.js $2, npm, Playwright's Chromium libraries" ;;
    php)    echo "PHP $2 CLI, Composer" ;;
    ruby)   echo "Ruby $2, RubyGems, Bundler" ;;
    java)   echo "Temurin JDK $2" ;;
    dotnet) echo ".NET SDK $2.0 ($( [ "$3" = true ] && echo LTS || echo STS))" ;;
  esac
}
anchor_of() { case "$1" in node) echo nodejs ;; dotnet) echo net-sdk ;; *) echo "$1" ;; esac; }
label_of() { # FAMILY CYCLE UPSTREAM CODENAME -- the image's OCI description
  local what flavor="" d
  case "$1" in
    python) what="Python $2" ;; node) what="Node.js $2" ;; php) what="PHP $2 CLI" ;;
    ruby) what="Ruby $2" ;; java) what="Temurin JDK $2" ;; dotnet) what=".NET SDK $2.0" ;;
  esac
  d=$(distro_of "$4")
  case "$3" in *slim*) flavor=" slim" ;; esac
  printf 'Shared CI image: %s on %s %s%s' "$what" "$d" "$(cap "$4")" "$flavor"
}
bullet_of() { # FAMILY CYCLE CODENAME LTS -- the docs/images.md bullet
  local on img
  on="on $(distro_of "$3") $(cap "$3")"; img=$(image_name "$1" "$2")
  case "$1" in
    python) echo "- **\`$img\`** — Python $2 and pip, $on. No compiler toolchain: projects that build native wheels add \`build-essential\` in their own workflow." ;;
    node)   echo "- **\`$img\`** — Node.js $2, npm, and Playwright's system libraries (Chromium only, no browser binaries; see [Running Playwright tests](#running-playwright-tests)), $on." ;;
    php)    echo "- **\`$img\`** — PHP $2 CLI plus the same pinned Composer as every PHP image, $on." ;;
    ruby)   echo "- **\`$img\`** — Ruby $2, RubyGems, and Bundler, $on. No compiler toolchain: projects with gems that build native extensions add \`build-essential\` in their own workflow." ;;
    java)   echo "- **\`$img\`** — the Temurin JDK $2, $on. No Maven and no Gradle: projects commit the wrapper (\`mvnw\`, \`gradlew\`) that pins the exact build version." ;;
    dotnet) echo "- **\`$img\`** — the .NET SDK $2.0 ($( [ "$4" = true ] && echo LTS || echo STS)), $on. No global tools: those are pinned per project in \`.config/dotnet-tools.json\`." ;;
  esac
}
# test.sh: the version assertion(s), and the pattern of the lines they replace.
assert_re() {
  case "$1" in
    python) echo '^check "python is [0-9]' ;; node) echo '^check "node is v[0-9]' ;; php) echo '^check "php is [0-9]' ;;
    ruby) echo '^check "ruby is [0-9]' ;; java) echo '^check "java is [0-9]' ;;
    dotnet) echo '^check "dotnet (sdk is [0-9]|lists an sdk")' ;;
  esac
}
assert_lines() { # FAMILY CYCLE
  local v="$2" major minor next
  case "$1" in
    python) printf 'check %-28s %s\n' "\"python is $v\"" "'[ \"\$(python -c \"import sys; print(\\\"%d.%d\\\" % sys.version_info[:2])\")\" = $v ]'" ;;
    node)   printf 'check %-28s %s\n' "\"node is v$v\"" "'[ \"\$(node -p \"process.versions.node.split(\\\".\\\")[0]\")\" = $v ]'" ;;
    php)    major=${v%%.*}; minor=${v#*.}; next="$major.$((minor + 1))"
            printf 'check %-28s %s\n' "\"php is $v\"" "'php -r \"exit(version_compare(PHP_VERSION, \\\"$v\\\", \\\">=\\\") && version_compare(PHP_VERSION, \\\"$next\\\", \\\"<\\\") ? 0 : 1);\"'" ;;
    ruby)   printf 'check %-28s %s\n' "\"ruby is $v\"" "'ruby -e \"exit(RUBY_VERSION.start_with?(\\\"$v.\\\") ? 0 : 1)\"'" ;;
    java)   printf 'check %-28s %s\n' "\"java is $v\"" "'java --version | head -1 | grep -qE \" ${v}[. ]\"'" ;;
    dotnet) printf 'check %-28s %s\n' "\"dotnet sdk is $v\"" "'dotnet --version | grep -q \"^$v\\.\"'"
            printf 'check %-28s %s\n' '"dotnet lists an sdk"' "'dotnet --list-sdks | grep -q \"^$v\\.\"'" ;;
  esac
}

# --- HTTP, with the fixture switch ------------------------------------------------
# 0: answered (body in OUT), 4: a definite "not found", 1: anything else.
http_fetch() { # URL OUT
  local url="$1" out="$2" f code key
  key=$(printf '%s' "$url" | cksum | cut -d' ' -f1)
  if [ -f "$tmp/http.$key" ]; then
    code=$(cat "$tmp/http.$key.rc"); [ "$code" -ne 0 ] || cp "$tmp/http.$key" "$out"; return "$code"
  fi
  code=0
  if [ -n "$fixtures" ]; then
    if ! f=$(awk -v u="$url" '$1 == u { print $2; found=1; exit } END { exit !found }' "$fixtures/urls"); then
      log "error: no fixture for $url -- refusing to reach the network in fixture mode"
      code=1
    else
      case "$f" in @404) code=4 ;; @fail) code=1 ;; *) cp "$fixtures/$f" "$out" ;; esac
    fi
  else
    local status
    status=$(curl -sS -L --retry 3 --max-time 30 -o "$out" -w '%{http_code}' "$url" 2>"$tmp/curl.err") || status=000
    case "$status" in
      2??) code=0 ;;
      404) code=4 ;;
      *) log "  $url: HTTP $status $(tr '\n' ' ' < "$tmp/curl.err")"; code=1 ;;
    esac
  fi
  : > "$tmp/http.$key"; [ "$code" -ne 0 ] || cp "$out" "$tmp/http.$key"; echo "$code" > "$tmp/http.$key.rc"
  return "$code"
}

# endoflife.date API v1: {schema_version, generated_at, last_modified,
# result: {name, ..., releases: [{name, codename, label, releaseDate, isLts,
# ltsFrom, isEoas, eoasFrom, isEol, eolFrom, isMaintained, latest}]}}.
# Writes the releases array to $tmp/eol-<product>.json.
eol_releases() { # PRODUCT
  local f="$tmp/eol-$1.json" rc=0
  [ -f "$f" ] && return 0
  [ -f "$f.failed" ] && return 1
  http_fetch "https://endoflife.date/api/v1/products/$1/" "$tmp/eol-$1.raw" || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e '.result.releases | type == "array" and length > 0
        and all(.[]; (.name | type == "string") and (.releaseDate | type == "string"))' \
        "$tmp/eol-$1.raw" >/dev/null 2>&1; then
    : > "$f.failed"; return 1
  fi
  jq '.result.releases' "$tmp/eol-$1.raw" > "$f"
}

# The newest released Debian stable / Ubuntu LTS, as "<cycle> <codename>".
newest_distro() { # debian|ubuntu
  local product=$1 sel
  [ "$1" = debian ] && sel='true' || sel='.isLts == true'
  eol_releases "$product" || return 1
  jq -r --arg today "$today" "[.[] | select($sel and .releaseDate <= \$today and (.codename | type == \"string\"))]
    | sort_by(.name | split(\".\") | map(tonumber? // 0)) | last // empty
    | \"\(.name) \(.codename | split(\" \")[0] | ascii_downcase)\"" "$tmp/eol-$product.json"
}

# Does the exact tag exist upstream, for both architectures? 0 yes, 4 no, 1 unknown.
probe() { # UPSTREAM
  local ref="$1" name tag out="$tmp/probe.json" rc=0
  name=${ref%:*}; tag=${ref##*:}
  case "$name" in
    mcr.microsoft.com/*)
      http_fetch "https://mcr.microsoft.com/v2/${name#mcr.microsoft.com/}/tags/list" "$out" || return $?
      jq -e '.tags | type == "array"' "$out" >/dev/null 2>&1 || return 1
      # A floating tag (11.0-resolute) exists from the first preview on; only a
      # full SDK version tag without a pre-release label (11.0.100-resolute) says
      # the line is GA. Both architecture-specific tags must be there too.
      local ga_re
      ga_re="^$(printf '%s' "${tag%%-*}" | sed 's/[.]/\\./g')\\.[0-9]+-${tag#*-}\$"
      jq -e --arg t "$tag" --arg ga "$ga_re" '
        .tags as $all
        | ($all | index($t)) != null and ($all | index($t + "-amd64")) != null
          and ($all | index($t + "-arm64v8")) != null and any($all[]; test($ga))' "$out" >/dev/null 2>&1 || return 4
      ;;
    */*) warn "no registry probe for $ref"; return 1 ;;
    *)
      http_fetch "https://hub.docker.com/v2/repositories/library/$name/tags/$tag" "$out" || return $?
      jq -e '.images | type == "array"' "$out" >/dev/null 2>&1 || return 1
      jq -e '[.images[].architecture] | index("amd64") != null and index("arm64") != null' "$out" >/dev/null || rc=4
      [ "$rc" -eq 0 ] || log "  $ref exists, but not for both linux/amd64 and linux/arm64"
      return "$rc"
      ;;
  esac
}

# ---------------------------------------------------------------------------------
# plan: what is due, one JSON object per line on stdout.
# ---------------------------------------------------------------------------------
plan() {
  local images="$root/.github/images.json" state="$root/.github/lifecycle.json"
  local fam product vre distros newest rel cyc rc
  [ -f "$state" ] || echo '[]' > "$tmp/empty-state.json"
  [ -f "$state" ] || state="$tmp/empty-state.json"
  members "$images" > "$tmp/members.tsv"

  for fam in $(families); do
    if ! grep -q "$(printf '\t')$fam$(printf '\t')" "$tmp/members.tsv"; then
      log "$fam: no image in this family; nothing to compare a new line with, so nothing is added"
      continue
    fi
    product=$(fam_field "$fam" 2); vre=$(fam_field "$fam" 3); distros=$(fam_field "$fam" 4)
    if ! eol_releases "$product"; then
      warn "$fam: endoflife.date ($product) could not be read; no add, deprecation or retirement for this family today"
      continue
    fi
    newest=$(awk -F'\t' -v f="$fam" '$2 == f { c = $3 } END { print c }' "$tmp/members.tsv")

    # --- add: every GA cycle newer than the newest image.
    while IFS=$'\t' read -r cyc lts_ok; do
      [ -n "$cyc" ] || continue
      if [ "$lts_ok" != true ]; then
        log "$fam $cyc: not added: $( [ "$fam" = node ] && echo "odd major, or its LTS date has not come yet" || echo "not an LTS release")"
        continue
      fi
      local kind dl code cname tmpl upstream found="" stop="" tried=""
      for kind in $distros; do
        if ! dl=$(newest_distro "$kind") || [ -z "$dl" ]; then
          warn "$fam $cyc: endoflife.date ($kind) could not be read, so the distribution cannot be chosen; not added today"
          stop=1; break
        fi
        cname=${dl#* }
        tmpl=$(fam_field "$fam" "$( [ "$kind" = debian ] && echo 5 || echo 6)")
        upstream=$(tmpl_fill "$tmpl" "$cyc" "$cname")
        rc=0; probe "$upstream" || rc=$?
        case "$rc" in
          0) found=$upstream; break ;;
          4) log "$fam $cyc: $upstream is not published (GA, both architectures) yet"
             tried="${tried:+$tried or }$upstream" ;;
          *) warn "$fam $cyc: the registry did not answer for $upstream; not added today"; stop=1; break ;;
        esac
      done
      if [ -z "$stop" ] && [ -z "$found" ]; then
        notice "$fam $cyc is released and supported upstream, but not yet published as $tried for both linux/amd64 and linux/arm64; added once it is"
      fi
      if [ -n "$stop" ] || [ -z "$found" ]; then continue; fi
      jq -nc --arg fam "$fam" --arg cyc "$cyc" --arg up "$found" --arg c "$cname" \
        --arg img "$(image_name "$fam" "$cyc")" --argjson lts "$(jq --arg c "$cyc" 'any(.[]; .name == $c and .isLts == true)' "$tmp/eol-$product.json")" \
        '{action:"add", image:$img, family:$fam, cycle:$cyc, upstream:$up, codename:$c, lts:$lts, key:$up}'
    done < <(jq -r --arg today "$today" --arg newest "$newest" --arg vre "^$vre\$" --arg fam "$fam" '
        .[] | select((.name | test($vre)) and .releaseDate <= $today
                     and (.isEol != true) and ((.eolFrom | type) != "string" or .eolFrom > $today))
        | [.name,
           (if $fam == "node" then ((.name | tonumber) % 2 == 0 and (.ltsFrom | type) == "string" and .ltsFrom <= $today)
            elif $fam == "java" then .isLts == true
            else true end | tostring)] | @tsv' "$tmp/eol-$product.json" \
      | while IFS=$'\t' read -r c ok; do ver_gt "$c" "$newest" && printf '%s\t%s\n' "$c" "$ok"; done; true)

    # --- deprecate / retire: every image in the family.
    local img cycle cn up line mirror eol st st_eol announced successor
    while IFS=$'\t' read -r img _ cycle cn up line mirror; do
      rel=$(jq -c --arg c "$cycle" '[.[] | select(.name == $c)][0] // empty' "$tmp/eol-$product.json")
      if [ -z "$rel" ]; then
        warn "$img: endoflife.date ($product) lists no cycle $cycle; its end of support is unknown"
        continue
      fi
      eol=$(jq -r '.eolFrom // ""' <<<"$rel")
      is_date "$eol" || continue   # no end of support announced
      st=$(jq -c --arg i "$img" '[.[] | select(.image == $i)][0] // empty' "$state")
      st_eol=""; announced=""
      if [ -n "$st" ]; then st_eol=$(jq -r '.eol // ""' <<<"$st"); announced=$(jq -r '.announced // ""' <<<"$st"); fi
      # A record whose dates cannot be read is not evidence of anything: an
      # empty or malformed `announced` would make date_add fail, and its empty
      # answer would read as "the 30-day notice has passed". So nothing is
      # done for the image until the record is fixed (check, in lint, says
      # how), rather than a retirement on a guess.
      if [ -n "$st" ] && { ! is_date "$announced" || ! is_date "$st_eol"; }; then
        warn "$img: .github/lifecycle.json has no valid announced/eol date for it (announced='$announced', eol='$st_eol'); not deprecated or retired until that is fixed"
        continue
      fi
      successor=$(successor_of "$img" "$fam" "$state")
      if [[ "$today" > "$eol" ]]; then
        if [ -n "$st" ] && [ "$st_eol" = "$eol" ]; then
          if ! [[ "$(date_add "$announced" "$MIN_NOTICE_DAYS")" > "$today" ]]; then
            jq -nc --arg i "$img" --arg f "$fam" --arg c "$cycle" --arg e "$eol" --arg s "$successor" \
              '{action:"retire", image:$i, family:$f, cycle:$c, eol:$e, successor:$s, key:$e}'
          else
            log "$img: past end of support ($eol), but announced only on $announced; retired once that is $MIN_NOTICE_DAYS days old"
          fi
          continue
        fi
      elif [[ "$(date_add "$eol" "-$NOTICE_DAYS")" > "$today" ]] && [ -z "$st" ]; then
        continue   # not yet due
      fi
      [ -n "$st" ] && [ "$st_eol" = "$eol" ] && continue   # announced, and still right
      jq -nc --arg i "$img" --arg f "$fam" --arg c "$cycle" --arg e "$eol" --arg s "$successor" \
        --arg was "$st_eol" '{action:"deprecate", image:$i, family:$f, cycle:$c, eol:$e, successor:$s, key:$e}
                             + (if $was == "" then {} else {previous_eol:$was} end)'
    done < <(awk -F'\t' -v f="$fam" '$2 == f' "$tmp/members.tsv")
  done
}

# The image to move to: the family's newest image that is not deprecated.
successor_of() { # IMAGE FAMILY STATE
  awk -F'\t' -v f="$2" -v i="$1" '$2 == f && $1 != i { print $1 }' "$tmp/members.tsv" \
    | while read -r m; do jq -e --arg m "$m" 'any(.[]; .image == $m)' "$3" >/dev/null || echo "$m"; done | tail -1
}

# ---------------------------------------------------------------------------------
# Editing the tree. Each step is checked; a failure stops the edit.
# ---------------------------------------------------------------------------------
json_write() { # FILE JQ-FILTER [ARGS...] -- rewrite FILE through jq, keeping jq's own format
  local f="$1" filter="$2"; shift 2
  jq "$@" "$filter" "$f" > "$f.new" && mv "$f.new" "$f"
}

dependabot_block() { # IMAGE
  cat <<EOF
  - package-ecosystem: docker
    directory: /$1
    schedule:
      interval: daily
    cooldown:
      default-days: 7
    ignore:
      - dependency-name: "*"
        update-types: ["version-update:semver-major", "version-update:semver-minor"]
EOF
}
# The docker entries' directories, one per line.
dependabot_dirs() { awk '/^  - package-ecosystem: docker$/ { d=1; next } /^  - / { d=0 } d && /^    directory: / { sub(/^    directory: \/?/, ""); print }' "$1"; }

catalog_row() { # FAMILY CYCLE UPSTREAM VERSION LTS
  printf '| [`%s`](docs/images.md#%s) | %s | `%s` | `%s` |\n' "$(image_name "$1" "$2")" "$(anchor_of "$1")" \
    "$(contents "$1" "$2" "$5")" "$3" "$4"
}

# The newest sibling to copy from. Skips one that carries something only it
# has -- an extra file, or a pinned ARG no other image of the family pins
# (ci-ruby40's json replacement) -- since that is a workaround for that line,
# not part of the family's shape. Falls back to the newest if all do.
template_sibling() { # FAMILY
  local fam="$1" sibs s f arg others ok=""
  sibs=$(awk -F'\t' -v f="$fam" '$2 == f { a[++n] = $1 } END { for (i = n; i > 0; i--) print a[i] }' "$tmp/members.tsv")
  for s in $sibs; do
    ok=$s
    for f in "$root/$s"/*; do
      case "${f##*/}" in Dockerfile.ci|test.sh) ;; *) ok=""; break ;; esac
    done
    if [ -n "$ok" ]; then
      while read -r arg; do
        others=$(for o in $sibs; do [ "$o" = "$s" ] || grep -l "^ARG $arg=" "$root/$o/Dockerfile.ci" 2>/dev/null; done | head -1)
        [ -n "$others" ] || { ok=""; break; }
      done < <(sed -nE 's/^ARG ([A-Z0-9_]+)=.*/\1/p' "$root/$s/Dockerfile.ci" | grep -vxE 'BASE_IMAGE|TARGETARCH' || true)
    fi
    [ -n "$ok" ] && { echo "$ok"; return 0; }
  done
  printf '%s\n' "$sibs" | head -1
}

apply_add() { # IMAGE UPSTREAM LTS
  local img="$1" up="$2" lts="${3:-false}" fam="" cyc="" cn="" f vre re t sib
  for f in $(families); do
    case "$img" in "ci-$f"[0-9]*) fam=$f ;; esac
  done
  [ -n "$fam" ] || die "$img: not a managed family"
  vre=$(fam_field "$fam" 3)
  for t in "$(fam_field "$fam" 5)" "$(fam_field "$fam" 6)"; do
    [ "$t" = - ] && continue
    re=$(tmpl_re "$t" "$vre")
    if printf '%s' "$up" | grep -qE "$re"; then
      cyc=$(printf '%s' "$up" | sed -E "s|$re|\\1|"); cn=$(printf '%s' "$up" | sed -E "s|$re|\\2|"); break
    fi
  done
  [ -n "$cyc" ] || die "$up is not a $fam upstream tag"
  [ "$(image_name "$fam" "$cyc")" = "$img" ] || die "$up is $(image_name "$fam" "$cyc"), not $img"
  [ ! -e "$root/$img" ] || die "$img already exists"
  ! jq -e --arg i "$img" 'any(.[]; .image == $i)' "$root/.github/images.json" >/dev/null || die "$img is already in images.json"

  members "$root/.github/images.json" > "$tmp/members.tsv"
  sib=$(template_sibling "$fam")
  [ -n "$sib" ] || die "$fam has no image to copy"
  local scyc scn sup smirror sline line="$cn-v1"
  IFS=$'\t' read -r _ _ scyc scn sup sline smirror < <(awk -F'\t' -v s="$sib" '$1 == s' "$tmp/members.tsv")
  log "add $img ($up, $line), copied from $sib"

  # Checked before anything is written: the sibling's version assertions are
  # the lines the new ones replace, so they must be exactly where expected.
  local are n
  are=$(assert_re "$fam")
  n=$(grep -cE "$are" "$root/$sib/test.sh" || true)
  [ "$n" -eq "$(assert_lines "$fam" "$cyc" | wc -l)" ] \
    || die "$sib/test.sh has $n version assertion(s) matching /$are/; expected $(assert_lines "$fam" "$cyc" | wc -l)"
  grep -q '^ARG BASE_IMAGE=' "$root/$sib/Dockerfile.ci" || die "$sib/Dockerfile.ci has no ARG BASE_IMAGE line"

  # --- the directory: the sibling's, with its version, base and distribution
  # moved, the description and version assertions regenerated.
  mkdir "$root/$img"
  cp -p "$root/$sib/Dockerfile.ci" "$root/$sib/test.sh" "$root/$img/"
  local repo_name=${sup%:*} srt rt sd nd
  srt=$(runtime "$fam" "$scyc"); rt=$(runtime "$fam" "$cyc")
  sd="$(distro_of "$scn") $(cap "$scn")"; nd="$(distro_of "$cn") $(cap "$cn")"
  # Literal parts escaped for sed -E; # is the delimiter (no value has one).
  local e_sib e_sup e_rn e_scyc e_srt e_label
  esc() { printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|/]/\\&/g'; }
  e_sib=$(esc "$sib"); e_sup=$(esc "$sup"); e_rn=$(esc "${repo_name##*/}"); e_scyc=$(esc "$scyc")
  e_srt=$(esc "$srt"); e_label=$(label_of "$fam" "$cyc" "$up" "$cn" | sed 's/[&#\\]/\\&/g')
  for f in "$root/$img/Dockerfile.ci" "$root/$img/test.sh"; do
    sed -E \
      -e "s#^ARG BASE_IMAGE=.*#ARG BASE_IMAGE=$up#" \
      -e "s#^LABEL org\\.opencontainers\\.image\\.description=.*#LABEL org.opencontainers.image.description=\"$e_label\"#" \
      -e "s#$e_sib([^0-9]|\$)#$img\\1#g" \
      -e "s#$e_sup#$up#g" \
      -e "s#(^|[^A-Za-z0-9.-])$e_rn:$e_scyc([^0-9.]|\$)#\\1${repo_name##*/}:$cyc\\2#g" \
      -e "s#$e_srt([^0-9.]|\$)#$rt\\1#g" \
      "$f" > "$f.new"
    # A new distribution: only the Dockerfile's comments still name the old
    # one (the ARG and LABEL are already rewritten). Not test.sh, whose
    # distribution-aware checks list codenames on purpose; and only the forms
    # that mean "this image's distribution": the tag suffix (-noble), the
    # version line (noble-v1) and the name in prose (Ubuntu Noble, Noble).
    if [ "$scn" != "$cn" ] && [ "${f##*/}" = Dockerfile.ci ]; then
      sed -E -e "/^#/s#$(esc "$sd")#$nd#g" -e "/^#/s#$scn-v1#$cn-v1#g" -e "/^#/s#-$scn([^A-Za-z-]|\$)#-$cn\\1#g" \
        -e "/^#/s#(^|[^A-Za-z])$(cap "$scn")([^A-Za-z]|\$)#\\1$(cap "$cn")\\2#g" "$f.new" > "$f.new2"
      mv "$f.new2" "$f.new"
    fi
    cat "$f.new" > "$f"; rm -f "$f.new"   # cat keeps test.sh executable
  done
  # Version assertions: exactly the family's lines, regenerated.
  assert_lines "$fam" "$cyc" > "$tmp/assert"
  awk -v re="$are" -v af="$tmp/assert" '
    $0 ~ re { if (!done) { while ((getline l < af) > 0) print l; done = 1 } next } { print }' \
    "$root/$img/test.sh" > "$root/$img/test.sh.new"
  cat "$root/$img/test.sh.new" > "$root/$img/test.sh"; rm -f "$root/$img/test.sh.new"
  # Nothing of the sibling's identity may survive: a stale image name or base
  # would build or test the wrong thing.
  local stale
  stale=$(grep -nE "$e_sib([^0-9]|\$)|$e_sup|(^|[^A-Za-z0-9.-])$e_rn:$e_scyc([^0-9.]|\$)" "$root/$img/Dockerfile.ci" "$root/$img/test.sh" || true)
  [ -z "$stale" ] || die "the scaffold still names $sib or its base: $stale"
  grep -qxF "ARG BASE_IMAGE=$up" "$root/$img/Dockerfile.ci" || die "no ARG BASE_IMAGE line in $sib/Dockerfile.ci"

  # --- images.json: family, then cycle.
  local mirror="${smirror%%:*}:${up##*:}"
  json_write "$root/.github/images.json" '. + [{image:$i, version:$v, mirror:$m, upstream:$u}]
    | sort_by(.image | capture("^(?<p>.*?)(?<n>[0-9]*)$") | [.p, (.n | if . == "" then -1 else tonumber end)])' \
    --arg i "$img" --arg v "$line" --arg m "$mirror" --arg u "$up"

  # --- dependabot.yml: one more docker entry, at the end.
  { printf '\n'; dependabot_block "$img"; } >> "$root/.github/dependabot.yml"

  # --- vulnerability exceptions: the sibling's unexpired package-scoped ones
  # (pkg:type/name@version) for the same upstream package. A new image is gated
  # against an empty baseline, so a finding upstream already carries -- and a
  # human already accepted, until the same expiry -- would otherwise hold the
  # new image back. Path-scoped entries name the sibling's version-specific
  # paths, so they could not apply and are not copied.
  json_write "$root/.github/vuln-exceptions.json" '
    . + [.[] | select(.image == $s and .expires > $today and (has("paths") | not) and has("purls")) | .image = $i]' \
    --arg s "$sib" --arg i "$img" --arg today "$today"

  # --- README: a catalog row above the family's newest, and the count.
  local row anchor_line
  row=$(catalog_row "$fam" "$cyc" "$up" "$line" "$lts")
  anchor_line=$(grep -nE "^\| \[\`ci-${fam}[0-9]+\`\]" "$root/README.md" | head -1 | cut -d: -f1)
  [ -n "$anchor_line" ] || die "README.md has no catalog row for the $fam family"
  awk -v n="$anchor_line" -v r="$row" 'NR == n { print r } { print }' "$root/README.md" > "$root/README.md.new"
  mv "$root/README.md.new" "$root/README.md"

  # --- docs/images.md: a bullet above the family's newest.
  local b
  b=$(bullet_of "$fam" "$cyc" "$cn" "$lts" | wrap '  ' 99)
  anchor_line=$(grep -nE "^- \*\*\`ci-${fam}[0-9]+\`\*\*" "$root/docs/images.md" | head -1 | cut -d: -f1)
  [ -n "$anchor_line" ] || die "docs/images.md has no bullet for the $fam family"
  printf '%s\n' "$b" > "$tmp/bullet"
  awk -v n="$anchor_line" -v bf="$tmp/bullet" 'NR == n { while ((getline l < bf) > 0) print l } { print }' \
    "$root/docs/images.md" > "$root/docs/images.md.new"
  mv "$root/docs/images.md.new" "$root/docs/images.md"

  render
}

apply_deprecate() { # IMAGE EOL [SUCCESSOR]
  local img="$1" eol="$2" succ="${3:-}" state="$root/.github/lifecycle.json" fam="" cyc
  is_date "$eol" || die "--eol must be YYYY-MM-DD"
  members "$root/.github/images.json" > "$tmp/members.tsv"
  IFS=$'\t' read -r _ fam cyc _ < <(awk -F'\t' -v i="$img" '$1 == i' "$tmp/members.tsv") || true
  [ -n "$fam" ] || die "$img is not a managed image in images.json"
  [ -f "$state" ] || echo '[]' > "$state"
  [ -n "$succ" ] || succ=$(successor_of "$img" "$fam" "$state")
  log "deprecate $img: end of support $eol${succ:+, successor $succ}"
  json_write "$state" '
    if any(.[]; .image == $i) then map(if .image == $i then .eol = $e | .successor = $s | .state = "deprecated" else . end)
    else . + [{image:$i, state:"deprecated", runtime:$r, eol:$e, announced:$t, successor:$s, notice:("deprecated-" + $i)}] end' \
    --arg i "$img" --arg e "$eol" --arg s "$succ" --arg t "$today" --arg r "$(runtime "$fam" "$cyc")"
  render
}

apply_retire() { # IMAGE
  local img="$1" state="$root/.github/lifecycle.json" fam="" cyc
  members "$root/.github/images.json" > "$tmp/members.tsv"
  IFS=$'\t' read -r _ fam cyc _ < <(awk -F'\t' -v i="$img" '$1 == i' "$tmp/members.tsv") || true
  [ -n "$fam" ] || die "$img is not a managed image in images.json"
  jq -e --arg i "$img" 'any(.[]; .image == $i and .state == "deprecated")' "$state" >/dev/null 2>&1 \
    || die "$img is not deprecated in .github/lifecycle.json; deprecate it first"
  log "retire $img"
  rm -rf "${root:?}/$img"
  json_write "$root/.github/images.json" 'map(select(.image != $i))' --arg i "$img"
  json_write "$root/.github/vuln-exceptions.json" 'map(select(.image != $i))' --arg i "$img"
  json_write "$state" 'map(if .image == $i then .state = "retired" | .retired = $t else . end)' --arg i "$img" --arg t "$today"
  # dependabot.yml: the entry -- exactly the standard one, which check
  # enforces -- and the blank line before it.
  local dl
  dl=$(grep -nxF "    directory: /$img" "$root/.github/dependabot.yml" | cut -d: -f1)
  [ -n "$dl" ] || die ".github/dependabot.yml has no entry for /$img"
  sed -n "$((dl - 1)),$((dl + 7))p" "$root/.github/dependabot.yml" | cmp -s - <(dependabot_block "$img") \
    || die ".github/dependabot.yml: the /$img entry is not the standard docker entry; not removing it blind"
  awk -v s="$((dl - 1))" -v e="$((dl + 7))" 'NR == s - 1 && /^$/ { next } NR >= s && NR <= e { next } { print }' \
    "$root/.github/dependabot.yml" > "$root/.github/dependabot.yml.new"
  mv "$root/.github/dependabot.yml.new" "$root/.github/dependabot.yml"
  # README row; docs/images.md bullet (and its continuation lines).
  grep -vE "^\| \[\`$img\`\]" "$root/README.md" > "$root/README.md.new" || true
  mv "$root/README.md.new" "$root/README.md"
  awk -v b="- **\`$img\`**" '
    index($0, b) == 1 { skip = 1; next }
    skip && /^  [^ ]/ { next }
    { skip = 0; print }' "$root/docs/images.md" > "$root/docs/images.md.new"
  mv "$root/docs/images.md.new" "$root/docs/images.md"
  # Usage examples that pull it -- a full ghcr.io reference, or the name as a
  # quoted string (a digests.json query) -- move to the successor. Prose that
  # merely names the image is left as written; the PR body lists it.
  local succ sline f
  succ=$(jq -r --arg i "$img" '.[] | select(.image == $i) | .successor' "$state")
  sline=$(line_of "$succ" 2>/dev/null || true)
  if [ -n "$succ" ] && [ -n "$sline" ]; then
    for f in README.md docs/*.md CONTRIBUTING.md SECURITY.md; do
      [ -f "$root/$f" ] || continue
      sed -E -e "s#$OWNER_REF/$img:[a-z]+-v[0-9]+#$OWNER_REF/$succ:$sline#g" -e "s#$OWNER_REF/$img@#$OWNER_REF/$succ@#g" \
        -e "s#\"$img\"#\"$succ\"#g" "$root/$f" > "$root/$f.new"
      cat "$root/$f.new" > "$root/$f"; rm -f "$root/$f.new"
    done
  fi
  render
}

# ---------------------------------------------------------------------------------
# render: the parts of the docs that follow from images.json and lifecycle.json.
# ---------------------------------------------------------------------------------
# Replace the lines between <!-- lifecycle:NAME:begin --> and :end with FILE.
region() { # DOC NAME FILE
  local doc="$1"
  if ! grep -qxF "<!-- lifecycle:$2:begin -->" "$doc" || ! grep -qxF "<!-- lifecycle:$2:end -->" "$doc"; then
    die "${doc#"$root"/} has no lifecycle:$2 region"
  fi
  awk -v b="<!-- lifecycle:$2:begin -->" -v e="<!-- lifecycle:$2:end -->" -v f="$3" '
    $0 == b { print; while ((getline l < f) > 0) print l; skip = 1; next }
    $0 == e { skip = 0 }
    !skip { print }' "$doc" > "$doc.new"
  mv "$doc.new" "$doc"
}

render() {
  local images="$root/.github/images.json" state="$root/.github/lifecycle.json"
  [ -f "$state" ] || echo '[]' > "$state"
  local n; n=$(jq length "$images")

  # README: the count, and each catalog row's deprecation marker.
  jq -r '.[] | select(.state == "deprecated") | "\(.image)=\(.eol)"' "$state" > "$tmp/dep.txt"
  awk -v n="$n" -v depf="$tmp/dep.txt" '
    BEGIN { while ((getline l < depf) > 0) { split(l, a, "="); dep[a[1]] = a[2] } }
    /There are [0-9]+:/ { sub(/There are [0-9]+:/, "There are " n ":") }
    /^\| \[`ci-[a-z0-9]+`\]\(/ {
      img = $0; sub(/^\| \[`/, "", img); sub(/`.*/, "", img)
      sub(/ \*\*\(deprecated[^)]*\)\*\*/, "")
      if (img in dep) { i = index($0, ") | "); $0 = substr($0, 1, i) " **(deprecated: retires after " dep[img] ")**" substr($0, i + 1) }
    }
    { print }' "$root/README.md" > "$root/README.md.new"
  mv "$root/README.md.new" "$root/README.md"

  render_readme_notices > "$tmp/r1"; region "$root/README.md" notices "$tmp/r1"
  render_images_status > "$tmp/r2";  region "$root/docs/images.md" status "$tmp/r2"
  render_security > "$tmp/r3";       region "$root/SECURITY.md" deprecated "$tmp/r3"
}

# One group per notice anchor (the dotnet8/dotnet9 notice is one group of two;
# every notice since is one image), members by version.
groups() { jq -r 'group_by(.notice) | sort_by([(map(.state == "retired") | all), (map(.eol) | max)]) | .[][0].notice' "$root/.github/lifecycle.json"; }
group_json() { jq -c --arg n "$1" '[.[] | select(.notice == $n)] | sort_by(.image | capture("(?<n>[0-9]*)$").n | tonumber? // 0)' "$root/.github/lifecycle.json"; }
# Lines on stdin joined as prose ("a", "a and b", "a, b and c"). No mapfile:
# scripts/lint.sh runs this on the bash 3.2 macOS ships, too.
join_lines() { local items=() l; while IFS= read -r l; do items+=("$l"); done; join_and ${items[@]+"${items[@]}"}; }
code_list() { jq -r '.[] | "`" + .image + "`"' | join_lines; }
runtime_list() { jq -r '.[].runtime' | join_lines; }
line_of() { jq -r --arg i "$1" '.[] | select(.image == $i) | .version' "$root/.github/images.json"; }
# n ONE MANY -- ONE when n is 1, else MANY ("both" for two, "all" for more, where MANY says both)
pick() { if [ "$1" -eq 1 ]; then printf '%s' "$2"; elif [ "$1" -eq 2 ]; then printf '%s' "$3"; else printf '%s' "${3//both/all}"; fi; }
# "<new distro>|<old distro>" when moving from the group's images to SUCCESSOR
# changes the distribution, else nothing.
distro_move() { # GROUP-JSON SUCCESSOR
  local sl c cl
  sl=$(line_of "$2"); sl=${sl%-v*}; [ -n "$sl" ] || return 0
  for c in $(jq -r '.[].image' <<<"$1"); do
    cl=$(line_of "$c"); cl=${cl%-v*}
    if [ -n "$cl" ] && [ "$cl" != "$sl" ]; then
      printf '%s %s|%s %s' "$(distro_of "$sl")" "$(cap "$sl")" "$(distro_of "$cl")" "$(cap "$cl")"; return 0
    fi
  done
}
render_readme_notices() {
  local g j dep n succ mv first=1
  for g in $(groups); do
    j=$(group_json "$g"); dep=$(jq -c '[.[] | select(.state == "deprecated")]' <<<"$j")
    n=$(jq length <<<"$dep"); [ "$n" -gt 0 ] || continue
    succ=$(jq -r '[.[].successor | select(. != "")] | last // ""' <<<"$dep")
    [ -n "$first" ] || echo
    first=""
    {
      printf '**Deprecated: %s.** %s %s end of support on **%s**, and %s retired after that date: %s rebuilt and re-scanned.' \
        "$(code_list <<<"$dep")" "$(runtime_list <<<"$dep")" "$(pick "$n" reaches reach)" "$(jq -r '[.[].eol] | max' <<<"$dep")" \
        "$(pick "$n" "the image is" "both images are")" "$(pick "$n" "it stops being" "they stop being")"
      if [ -n "$succ" ]; then
        mv=$(distro_move "$dep" "$succ")
        printf ' Move to `%s`%s.' "$succ" "${mv:+ (${mv%%|*}, so check that any extra \`apt-get\` package names still resolve)}"
      fi
      printf ' Details in [docs/images.md](docs/images.md#%s).\n' "$g"
    } | wrap '' 99
  done
}
render_images_status() {
  local g j dep ret nd nr succ heading slug mv any=""
  for g in $(groups); do
    any=1
    j=$(group_json "$g")
    dep=$(jq -c '[.[] | select(.state == "deprecated")]' <<<"$j"); ret=$(jq -c '[.[] | select(.state == "retired")]' <<<"$j")
    nd=$(jq length <<<"$dep"); nr=$(jq length <<<"$ret")
    succ=$(jq -r '[.[].successor | select(. != "")] | last // ""' <<<"$j")
    if [ "$nd" -eq 0 ]; then heading="Retired: $(code_list <<<"$j")"; else heading="Deprecated: $(code_list <<<"$j")"; fi
    # GitHub's heading anchor. Where it is not the notice's own anchor (once
    # retired), the old anchor is kept alive with an explicit one.
    slug=$(printf '%s' "$heading" | tr '[:upper:]' '[:lower:]' | tr -d '`' | sed 's/[^a-z0-9_ -]//g; s/ /-/g')
    echo
    [ "$slug" = "$g" ] || printf '<a id="%s"></a>\n\n' "$g"
    printf '### %s\n\n' "$heading"
    if [ "$nd" -gt 0 ]; then
      printf '%s %s end of support upstream on **%s**. After that date %s no security fixes upstream, so rebuilding %s daily would only keep producing fresh digests of an unpatched runtime.\n' \
        "$(runtime_list <<<"$dep")" "$(pick "$nd" reaches reach)" "$(jq -r '[.[].eol] | max' <<<"$dep")" \
        "$(pick "$nd" "it receives" "they receive")" "$(pick "$nd" "this image" "these images")" | wrap '' 99
      echo
      if [ -n "$succ" ]; then
        mv=$(distro_move "$dep" "$succ")
        printf -- '- **Move to `%s`** (`%s/%s:%s`).%s\n' "$succ" "$OWNER_REF" "$succ" "$(line_of "$succ")" \
          "${mv:+ It is ${mv%%|*} rather than ${mv#*|}, so a job that installs extra packages with \`apt-get\` should check that their names still resolve.}" | wrap '  ' 99
      fi
      printf -- '- **Retired automatically after %s**, and no sooner than %s days after this notice: the image lifecycle workflow opens a pull request that removes %s from the build, so %s rebuilt and re-scanned. Until then %s built, scanned and published as normal.\n' \
        "$(jq -r '[.[].eol] | max' <<<"$dep")" "$MIN_NOTICE_DAYS" "$(pick "$nd" it them)" "$(pick "$nd" "it stops being" "they stop being")" \
        "$(pick "$nd" "it is" "they are")" | wrap '  ' 99
      printf -- '- Retiring an image does not delete its published package (see [Tags and rebuilds](pipeline.md#tags-and-rebuilds)); deleting the GHCR package is a separate decision for the repository owner.\n' | wrap '  ' 99
    fi
    if [ "$nr" -gt 0 ]; then
      [ "$nd" -eq 0 ] || echo
      printf '%s reached end of support upstream on %s. Retired, and no longer rebuilt or re-scanned: %s. A retired package stays pullable until the owner deletes it, collecting unpatched vulnerabilities%s.\n' \
        "$(runtime_list <<<"$ret")" "$(jq -r '[.[].eol] | max' <<<"$ret")" \
        "$(jq -r '.[] | "`\(.image)` on \(.retired)"' <<<"$ret" | join_lines)" \
        "${succ:+, so move to \`$succ\`}" | wrap '' 99
    fi
  done
  [ -n "$any" ] || { echo; echo "No image is deprecated or retired at the moment."; }
  echo
}
render_security() {
  local g j dep n succ
  for g in $(groups); do
    j=$(group_json "$g"); dep=$(jq -c '[.[] | select(.state == "deprecated")]' <<<"$j")
    n=$(jq length <<<"$dep"); [ "$n" -gt 0 ] || continue
    succ=$(jq -r '[.[].successor | select(. != "")] | last // ""' <<<"$dep")
    echo
    printf '%s %s deprecated: %s %s end of support on %s, and %s retired after that date.%s\n' \
      "$(code_list <<<"$dep")" "$(pick "$n" is are)" "$(runtime_list <<<"$dep")" "$(pick "$n" reaches reach)" \
      "$(jq -r '[.[].eol] | max' <<<"$dep")" "$(pick "$n" "the image is" "both images are")" \
      "${succ:+ Use \`$succ\`.}" | wrap '' 99
  done
}

# ---------------------------------------------------------------------------------
# check: the consistency scripts/lint.sh gates on. Prints every problem.
# ---------------------------------------------------------------------------------
check() {
  local images="$root/.github/images.json" state="$root/.github/lifecycle.json" bad=0
  problem() { log "error: $*"; bad=1; }
  [ -f "$state" ] || { problem ".github/lifecycle.json is missing"; return 3; }
  jq -e 'type == "array" and all(.[]; (.image | type == "string") and (.state == "deprecated" or .state == "retired")
         and (.eol | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and (.announced | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
         and (.notice | test("^[a-z0-9-]+$")) and (.runtime | type == "string") and (.successor | type == "string")
         and (.state == "deprecated" or (.retired | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))))' "$state" >/dev/null 2>&1 \
    || { problem ".github/lifecycle.json: every entry needs image, state (deprecated|retired), runtime, eol, announced, successor, notice (and retired, once retired)"; return 3; }

  local set_json set_dep set_readme set_bullets d dl
  set_json=$(jq -r '.[].image' "$images" | sort)
  # dependabot.yml: one docker entry per image, each the same shape.
  set_dep=$(dependabot_dirs "$root/.github/dependabot.yml" | sort)
  [ "$set_dep" = "$set_json" ] || problem ".github/dependabot.yml docker directories differ from images.json: $(diff <(echo "$set_dep") <(echo "$set_json") | grep '^[<>]' | tr '\n' ' ')"
  for d in $set_dep; do
    dl=$(grep -nxF "    directory: /$d" "$root/.github/dependabot.yml" | head -1 | cut -d: -f1)
    sed -n "$((dl - 1)),$((dl + 7))p" "$root/.github/dependabot.yml" > "$tmp/dep-block"
    cmp -s "$tmp/dep-block" <(dependabot_block "$d") \
      || problem ".github/dependabot.yml: the /$d entry is not the standard docker entry (daily, 7-day cooldown, ignore semver-major and -minor)"
  done
  # Each Dockerfile builds what images.json says, mirrored under the same tag,
  # on the version line its base's distribution names.
  while IFS=$'\t' read -r img ver mirror up; do
    d=$(sed -nE 's/^ARG BASE_IMAGE=(.*)$/\1/p' "$root/$img/Dockerfile.ci" 2>/dev/null | head -1)
    [ "$d" = "$up" ] || problem "$img/Dockerfile.ci: ARG BASE_IMAGE=${d:-(none)}, but images.json says $up"
    [ "${mirror##*:}" = "${up##*:}" ] || problem "$img: mirror $mirror does not carry the upstream tag ${up##*:}"
    case "$ver" in *-v[0-9]*) ;; *) problem "$img: version $ver is not <codename>-v<N>" ;; esac
    case "${up##*:}" in *"${ver%-v*}"*) ;; *) problem "$img: version line $ver names a distribution its base $up is not" ;; esac
  done < <(jq -r '.[] | [.image, .version, .mirror, .upstream] | @tsv' "$images")
  # Family images: named for their cycle.
  members "$images" > "$tmp/members.tsv"
  while IFS=$'\t' read -r img fam cyc _; do
    [ "$(image_name "$fam" "$cyc")" = "$img" ] || problem "$img: its base is $fam $cyc, so it would be $(image_name "$fam" "$cyc")"
  done < "$tmp/members.tsv"
  for img in $(jq -r '.[].image' "$images"); do
    for fam in $(families); do
      case "$img" in "ci-$fam"[0-9]*) grep -q "^$img	" "$tmp/members.tsv" \
        || problem "$img: named like a $fam image, but its upstream is not a $fam tag shape the lifecycle reads" ;; esac
    done
  done
  # README catalog: one row per image, with its base and tag; the count.
  set_readme=$(grep -oE '^\| \[`ci-[a-z0-9]+`\]' "$root/README.md" | sed 's/^| \[`//; s/`\]$//' | sort)
  [ "$set_readme" = "$set_json" ] || problem "README.md catalog rows differ from images.json: $(diff <(echo "$set_readme") <(echo "$set_json") | grep '^[<>]' | tr '\n' ' ')"
  while IFS=$'\t' read -r img ver up; do
    grep -qE "^\| \[\`$img\`\].* \| \`$(printf '%s' "$up" | sed 's/[.]/\\./g')\` \| \`$ver\` \|$" "$root/README.md" \
      || problem "README.md: the $img row does not show base \`$up\` and tag \`$ver\`"
  done < <(jq -r '.[] | [.image, .version, .upstream] | @tsv' "$images")
  grep -qE "There are $(jq length "$images"):" "$root/README.md" || problem "README.md: \"There are N:\" does not say $(jq length "$images")"
  # docs/images.md: one bullet per image.
  set_bullets=$(grep -oE '^- \*\*`ci-[a-z0-9]+`\*\*' "$root/docs/images.md" | sed 's/^- \*\*`//; s/`\*\*$//' | sort)
  [ "$set_bullets" = "$set_json" ] || problem "docs/images.md image bullets differ from images.json: $(diff <(echo "$set_bullets") <(echo "$set_json") | grep '^[<>]' | tr '\n' ' ')"
  # lifecycle.json against images.json.
  for img in $(jq -r '.[] | select(.state == "deprecated") | .image' "$state"); do
    grep -qx "$img" <<<"$set_json" || problem "lifecycle.json: $img is deprecated but not in images.json (retired? set its state)"
  done
  for img in $(jq -r '.[] | select(.state == "retired") | .image' "$state"); do
    grep -qx "$img" <<<"$set_json" && problem "lifecycle.json: $img is retired but still in images.json"
  done
  for d in $(jq -r '.[] | select(.successor != "") | .successor' "$state" | sort -u); do
    jq -e --arg d "$d" 'any(.[]; .image == $d and .state == "deprecated")' "$state" >/dev/null \
      && jq -e --arg d "$d" 'any(.[]; .successor == $d and .state == "deprecated")' "$state" >/dev/null \
      && problem "lifecycle.json: $d is named as a successor but is deprecated itself"
  done
  # The generated parts are what render makes of the current state.
  local copy="$tmp/check-copy" f
  mkdir -p "$copy/.github" "$copy/docs"
  for f in README.md SECURITY.md docs/images.md .github/images.json .github/lifecycle.json; do cp "$root/$f" "$copy/$f"; done
  # A subshell, so render works on the copy and root is the real tree after.
  # shellcheck disable=SC2030,SC2031
  if ( root=$copy; render ) 2> "$tmp/render.err"; then
    for f in README.md SECURITY.md docs/images.md; do
      cmp -s "$root/$f" "$copy/$f" || problem "$f: the lifecycle parts (deprecation markers, notices, count) are not what .github/lifecycle.json says; run ./scripts/image-lifecycle.sh render: $(diff "$root/$f" "$copy/$f" | head -6 | tr '\n' ' ')"
    done
  else
    problem "render failed: $(tr '\n' ' ' < "$tmp/render.err")"
  fi
  [ "$bad" -eq 0 ] || return 3
  log "lifecycle check: $(jq length "$images") images consistent across images.json, dependabot.yml, Dockerfiles, README.md, docs/images.md and lifecycle.json"
}

# ---------------------------------------------------------------------------------
# prs: one pull request per action.
# ---------------------------------------------------------------------------------
run() {
  if [ -n "$dry" ]; then
    printf 'DRY-RUN would run:' >&2; printf ' %q' "$@" >&2; printf '\n' >&2
    return 0
  fi
  "$@"
}
local_run() { printf '+' >&2; printf ' %q' "$@" >&2; printf '\n' >&2; "$@"; }
gh_read() {
  local name="$1"; shift
  if [ -n "$stub" ]; then
    if [ -f "$stub/$name.json" ]; then cat "$stub/$name.json"; else echo '[]'; fi
    if [ -f "$stub/$name.exit" ]; then return "$(cat "$stub/$name.exit")"; fi
    return 0
  fi
  gh "$@"
}
# Called only through run/local_run, which shellcheck cannot follow.
# shellcheck disable=SC2329
git_net() {
  # shellcheck disable=SC2016,SC2317
  git -c credential.helper= \
      -c 'credential.helper=!f() { echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f' "$@"
}

one_action() { # ACTION-JSON
  local a="$1" action img key branch slug wt
  action=$(jq -r .action <<<"$a"); img=$(jq -r .image <<<"$a"); key=$(jq -r .key <<<"$a")
  branch="lifecycle/$action-$img"; slug=${branch//\//_}; wt="$work/wt-$action-$img"
  local remote_sha pr_all open_json pr_num="" pr_url="" prev_key="" closed_same note="" errors="" status=""
  local result_action=""

  row() { # STATUS ACTION
    jq -nc --arg a "$action" --arg i "$img" --arg k "$key" --arg pr "$pr_url" --arg s "$1" --arg act "$2" --arg n "$note" \
      '{action:$a, image:$i, key:$k, pr:$pr, status:$s, did:$act, note:$n}' >> "$RESULTS"
  }

  remote_sha=$(git rev-parse -q --verify "refs/remotes/origin/$branch" || true)
  pr_all=$(gh_read "pr-$slug" pr list --repo "$repo" --head "$branch" --base "$base" --state all \
            --limit 50 --json number,state,url,body,headRefName,isCrossRepository)
  pr_all=$(jq -c --arg b "$branch" '[.[] | select(.headRefName == $b and (.isCrossRepository | not))]' <<<"$pr_all")
  open_json=$(jq -c '[.[] | select(.state == "OPEN")][0] // empty' <<<"$pr_all")
  if [ -n "$open_json" ]; then
    pr_num=$(jq -r .number <<<"$open_json"); pr_url=$(jq -r .url <<<"$open_json")
    prev_key=$(jq -r '.body // ""' <<<"$open_json" | sed -nE 's/.*<!-- image-lifecycle: action=[a-z]+ image=[^ ]+ key=([^ ]+) -->.*/\1/p' | head -1)
  fi
  closed_same=$(jq -r --arg k "key=$key -->" '[.[] | select(.state == "CLOSED" and ((.body // "") | contains($k)))][0].url // empty' <<<"$pr_all")
  if [ -z "$open_json" ] && [ -n "$closed_same" ]; then
    row skipped "not reopened: $closed_same was closed unmerged for the same change"
    return 0
  fi

  if [ -n "$remote_sha" ]; then
    local emails rc=0 foreign
    emails=$(git log --format='%ae%n%ce' "origin/$base..$remote_sha") || rc=$?
    if [ "$rc" -ne 0 ]; then note="could not list the commits on $branch (git log exit $rc)"; row error none; return 1; fi
    foreign=$(printf '%s\n' "$emails" | grep -vxF "$BOT_EMAIL" | grep -v '^$' | sort -u | paste -sd, - || true)
    if [ -n "$foreign" ]; then
      note="commits by $foreign; the branch is left to them, and merge-bot-prs.sh will not merge it"
      row skipped "$branch has commits not made by this workflow${pr_num:+ (#$pr_num)}"
      return 0
    fi
  fi

  if [ -n "$open_json" ] && [ "$prev_key" = "$key" ] && [ -n "$remote_sha" ] \
     && git merge-base --is-ancestor "origin/$base" "$remote_sha"; then
    heal "$remote_sha"
    return $?
  fi
  [ -n "$open_json" ] && [ "$prev_key" = "$key" ] && note="rebuilt because the branch was behind $base. "

  # --- rebuild the branch from the base, in a throwaway worktree.
  rm -rf "$wt"
  local_run git worktree add --quiet --detach "$wt" "origin/$base"
  local rc=0 args=()
  case "$action" in
    add)       args=(add --image "$img" --upstream "$(jq -r .upstream <<<"$a")" --lts "$(jq -r .lts <<<"$a")") ;;
    deprecate) args=(deprecate --image "$img" --eol "$(jq -r .eol <<<"$a")" --successor "$(jq -r .successor <<<"$a")") ;;
    retire)    args=(retire --image "$img") ;;
  esac
  LIFECYCLE_TODAY="$today" "$BASH" "$script_dir/image-lifecycle.sh" apply "${args[@]}" --root "$wt" \
    > "$work/apply-$slug.out" 2> "$work/apply-$slug.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    note="${note}the edit failed (exit $rc): $(tail -3 "$work/apply-$slug.err" | tr '\n' ' ')"
    row error "none"; return 1
  fi
  rc=0; LIFECYCLE_TODAY="$today" "$BASH" "$script_dir/image-lifecycle.sh" check --root "$wt" 2> "$work/check-$slug.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    note="${note}the edited tree fails the lifecycle check: $(grep '^error' "$work/check-$slug.err" | head -3 | tr '\n' ' ')"
    row error "none"; return 1
  fi
  local_run git -C "$wt" add -A
  # GITHUB_TOKEN may not push workflow files, and nothing here should change
  # them: stop rather than push a branch that is refused or, worse, accepted.
  if git -C "$wt" diff --cached --name-only | grep -q '^\.github/workflows/'; then
    note="${note}the edit touched .github/workflows/, which this workflow never changes"; row error none; return 1
  fi

  local title body="$work/body-$slug.md"
  title=$(pr_title "$a")
  printf '%s\n\nMade by scripts/image-lifecycle.sh from endoflife.date and the upstream registry (docs/adr/0009-image-lifecycle.md).\n' \
    "$title" > "$work/msg-$slug"
  local_run env GIT_AUTHOR_NAME="$BOT_NAME" GIT_AUTHOR_EMAIL="$BOT_EMAIL" \
    GIT_COMMITTER_NAME="$BOT_NAME" GIT_COMMITTER_EMAIL="$BOT_EMAIL" \
    git -C "$wt" commit --quiet --file "$work/msg-$slug"
  pr_body "$a" "$wt" > "$body"
  if [ -n "$dry" ]; then
    git -C "$wt" show --stat --format='commit by %an <%ae>, committer %cn <%ce>%n%n%B' HEAD >&2
    sed 's/^/  | /' "$body" >&2
  fi

  rc=0
  run git_net -C "$wt" push --quiet --force-with-lease="refs/heads/$branch:$remote_sha" origin "HEAD:refs/heads/$branch" || rc=$?
  if [ "$rc" -ne 0 ]; then
    note="${note}push refused (exit $rc): $branch moved since this run fetched it, or the push was not allowed"
    row error none; return 1
  fi
  if [ -n "$pr_num" ]; then
    run gh pr edit "$pr_num" --repo "$repo" --title "$title" --body-file "$body"
    result_action="updated #$pr_num${prev_key:+ (was $prev_key)}"
  elif [ -n "$dry" ]; then
    run gh pr create --repo "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$body"
    pr_url="(dry run)"; result_action="opened"
  else
    pr_url=$(gh pr create --repo "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$body")
    result_action="opened"
  fi
  dispatch build-and-push.yml security.yml
  finish
}

dispatch() { # WORKFLOW...
  local wf rc
  for wf in "$@"; do
    rc=0; run gh workflow run "$wf" --repo "$repo" --ref "$branch" || rc=$?
    if [ "$rc" -eq 0 ]; then result_action="$result_action, $wf dispatched"
    else errors="${errors}gh workflow run $wf failed (exit $rc). "; fi
  done
}
ci_missing() { # SHA
  local sha="$1" pair c wf out rc missing=""
  for pair in "${CHECK_WORKFLOWS[@]}"; do
    c=${pair%%|*}; wf=${pair#*|}
    case " $missing " in *" $wf "*) continue ;; esac
    rc=0
    out=$(gh_read "checks-$slug" api "repos/$repo/commits/$sha/check-runs?check_name=$(jq -rn --arg c "$c" '$c | @uri')&per_page=100") || rc=$?
    if [ "$rc" -ne 0 ] || ! jq -e '.check_runs | type == "array"' <<<"$out" >/dev/null 2>&1; then return 1; fi
    jq -e --arg c "$c" 'any(.check_runs[]; .name == $c and .conclusion != "cancelled")' <<<"$out" >/dev/null || missing="$missing $wf"
  done
  printf '%s' "${missing# }"
}
heal() { # HEAD_SHA
  local sha="$1" missing rc=0
  result_action="#$pr_num already up to date"
  missing=$(ci_missing "$sha") || rc=$?
  if [ "$rc" -ne 0 ]; then
    errors="${errors}could not read the check runs on ${sha:0:12}, so CI was neither confirmed nor re-dispatched. "
  elif [ -n "$missing" ]; then
    result_action="$result_action; checks missing on ${sha:0:12}"
    # shellcheck disable=SC2086  # one workflow file per word
    dispatch $missing
  else
    result_action="$result_action; checks present on ${sha:0:12}"
  fi
  finish unchanged
}
finish() { # [STATUS]
  note="${errors}${note}"; note=${note% }
  if [ -n "$errors" ]; then row error "$result_action"; return 1; fi
  row "${1:-ok}" "$result_action"
}

pr_title() { # ACTION-JSON
  local a="$1" fam cyc
  fam=$(jq -r .family <<<"$a"); cyc=$(jq -r .cycle <<<"$a")
  case "$(jq -r .action <<<"$a")" in
    add) printf 'Add %s: %s on %s %s' "$(jq -r .image <<<"$a")" "$(runtime "$fam" "$cyc")" \
           "$(distro_of "$(jq -r .codename <<<"$a")")" "$(cap "$(jq -r .codename <<<"$a")")" ;;
    deprecate) printf 'Deprecate %s: %s reaches end of support on %s' "$(jq -r .image <<<"$a")" "$(runtime "$fam" "$cyc")" "$(jq -r .eol <<<"$a")" ;;
    retire) printf 'Retire %s: %s reached end of support on %s' "$(jq -r .image <<<"$a")" "$(runtime "$fam" "$cyc")" "$(jq -r .eol <<<"$a")" ;;
  esac
}
pr_body() { # ACTION-JSON WORKTREE
  local a="$1" wt="$2" action img
  action=$(jq -r .action <<<"$a"); img=$(jq -r .image <<<"$a")
  echo "Automated image lifecycle change, opened by the daily image lifecycle workflow ([ADR 0009](docs/adr/0009-image-lifecycle.md))."
  echo
  case "$action" in
    add)
      echo "Upstream ships a new supported line: **$(runtime "$(jq -r .family <<<"$a")" "$(jq -r .cycle <<<"$a")")**, GA and published"
      echo "as \`$(jq -r .upstream <<<"$a")\` for \`linux/amd64\` and \`linux/arm64\`. This adds \`$img\` on the version line"
      echo "\`$(jq -r '.codename + "-v1"' <<<"$a")\`, copied from its newest sibling with the version, base and distribution moved."
      echo
      echo "**One manual step after this merges and the image first publishes:** GHCR creates the new"
      echo "\`$img\` package **private**, and no workflow token can change that (there is no API for package"
      echo "visibility). Until it is public, pulls from other repositories fail with \`denied\`, and the published-image"
      echo "audit reports it. Package page → *Package settings* → *Change visibility* → **Public**"
      echo "([docs/images.md](docs/images.md#visibility-and-authentication))."
      local copied
      copied=$(jq -r --arg i "$img" '.[] | select(.image == $i) | "- `\(.id)` in `\(.package)` (\(.purls | join(", "))), expires \(.expires)"' "$wt/.github/vuln-exceptions.json")
      if [ -n "$copied" ]; then
        echo
        echo "Vulnerability exceptions copied from the sibling, unchanged expiry (a new image is gated against an"
        echo "empty baseline, so findings upstream already carries would otherwise block it):"
        echo
        echo "$copied"
      fi
      echo
      echo "A new image is gated strictly: every fixable HIGH/CRITICAL finding blocks it, since nothing is published to"
      echo "compare with. If CI is red on one that upstream has not fixed yet, this PR waits; the daily run rebuilds it"
      echo "from \`$base\`, and an exception in \`.github/vuln-exceptions.json\` is the way through."
      ;;
    deprecate)
      echo "\`$img\` reaches upstream end of support on **$(jq -r .eol <<<"$a")** (endoflife.date, end of security fixes)."
      echo "This announces it: the catalog row, the README and SECURITY.md notices and docs/images.md, all generated"
      echo "from \`.github/lifecycle.json\`. No image changes, so CI builds nothing."
      [ "$(jq -r '.previous_eol // ""' <<<"$a")" = "" ] || echo "The date moved from $(jq -r .previous_eol <<<"$a") upstream."
      echo
      echo "The retirement follows automatically after that date, at least $MIN_NOTICE_DAYS days after this merges."
      ;;
    retire)
      echo "\`$img\` reached upstream end of support on **$(jq -r .eol <<<"$a")**, and its deprecation was announced"
      echo "ahead of it. This removes it from the build: the directory, its \`images.json\`, Dependabot and"
      echo "vulnerability-exception entries, and its catalog row. docs/images.md keeps a *Retired* note, and the"
      echo "anchor that linked to the deprecation notice."
      echo
      echo "**Not automatable, for the owner:** the published \`$img\` package stays pullable, collecting unpatched"
      echo "vulnerabilities, until it is deleted (package page → *Package settings* → *Delete this package*), and so"
      echo "does its \`mirror-*\` tag ([Tags and rebuilds](docs/pipeline.md#tags-and-rebuilds))."
      ;;
  esac
  echo
  echo "This PR **merges itself** (squash) once all four required checks pass on its head commit. It will not merge"
  echo "red. Add the \`hold\` label to stop it. CI was started by dispatching *Build and Push to GHCR* and *Security* on"
  echo "this branch, since a push made with the workflow token triggers no workflow."
  echo
  echo "Please do not use *Update branch* here: the daily run rebuilds a branch that fell behind \`$base\` itself, and"
  echo "never pushes over a commit it did not make."
  echo
  [ -n "${RUN_URL:-}" ] && { echo "Run: $RUN_URL"; echo; }
  echo "<!-- image-lifecycle: action=$action image=$img key=$(jq -r .key <<<"$a") -->"
}

prs() {
  [ -n "$repo" ] || die "GITHUB_REPOSITORY is required"
  if [ -z "$stub" ]; then command -v gh >/dev/null || die "gh not found"; fi
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "the checkout has uncommitted changes"
  work=$(mktemp -d)
  # shellcheck disable=SC2064  # $work and $tmp are fixed by now
  trap "rm -rf '$work' '$tmp'; git worktree prune" EXIT INT TERM
  RESULTS="$work/results.jsonl"; : > "$RESULTS"
  WARNINGS="$work/warnings.txt"; : > "$WARNINGS"
  NOTICES="$work/notices.txt"; : > "$NOTICES"
  export work RESULTS WARNINGS NOTICES

  local_run git_net fetch --quiet --no-tags --prune origin \
    "+refs/heads/$base:refs/remotes/origin/$base" "+refs/heads/lifecycle/*:refs/remotes/origin/lifecycle/*"
  # The plan reads the base branch as it is now, not this checkout.
  local_run git worktree add --quiet --detach "$work/base" "origin/$base"
  root="$work/base" plan > "$work/plan.jsonl"

  local a rc before
  while IFS= read -r a; do
    log ""; log "== $(jq -r '.action + " " + .image + " (" + .key + ")"' <<<"$a")"
    before=$(wc -l < "$RESULTS"); rc=0
    LIFECYCLE_TODAY="$today" "$BASH" "$script_dir/image-lifecycle.sh" --one-action "$a" || rc=$?
    if [ "$(wc -l < "$RESULTS")" -eq "$before" ]; then
      jq -nc --argjson a "$a" --arg rc "$rc" '{action:$a.action, image:$a.image, key:$a.key, pr:"", status:"error", did:"none", note:("aborted, exit " + $rc)}' >> "$RESULTS"
    fi
  done < "$work/plan.jsonl"

  {
    echo "### Image lifecycle${dry:+ (dry run)}"
    echo
    echo "Today is $today (UTC). Rules: [ADR 0009](https://github.com/$repo/blob/$base/docs/adr/0009-image-lifecycle.md)."
    echo
    if [ ! -s "$RESULTS" ]; then
      echo "Nothing is due: no new GA line, no deprecation, no retirement."
    else
      echo "| action | image | PR | result |"
      echo "|---|---|---|---|"
      jq -r 'def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
        "| \(.action) | `\(.image)` | \(if .pr == "" then "—" else .pr end) | \(if .status == "error" then "**error**: " else .status + ": " end)\(.did | cell)\(if .note != "" then " — " + (.note | cell) else "" end) |"' "$RESULTS"
    fi
    if [ -s "$NOTICES" ]; then
      echo
      echo "Waiting for an upstream tag (checked again tomorrow):"
      echo
      sed 's/^/- /' "$NOTICES"
    fi
    if [ -s "$WARNINGS" ]; then
      echo
      echo "Warnings (no action was taken on anything they affect):"
      echo
      sed 's/^/- /' "$WARNINGS"
    fi
  } > "$work/summary.md"
  [ -z "${LIFECYCLE_RESULTS:-}" ] || cp "$RESULTS" "$LIFECYCLE_RESULTS"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$work/summary.md" >> "$GITHUB_STEP_SUMMARY"
  cat "$work/summary.md"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    sed 's/^/::notice::/' "$NOTICES"
    sed 's/^/::warning::/' "$WARNINGS"
    jq -r 'select(.status == "error") | "::error::\(.action) \(.image): \(.note)"' "$RESULTS"
  fi
  local errors; errors=$(jq -s '[.[] | select(.status == "error")] | length' "$RESULTS")
  if [ "$errors" -gt 0 ]; then log "error: $errors action(s) failed; see the summary"; exit 1; fi
  exit 0
}

# ---------------------------------------------------------------------------------
usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

for cmd in jq git awk sed sort curl; do command -v "$cmd" >/dev/null || die "$cmd not found"; done
is_date "$today" || die "LIFECYCLE_TODAY must be YYYY-MM-DD"
if [ -n "$fixtures" ]; then
  [ -f "$fixtures/urls" ] || die "LIFECYCLE_FIXTURES=$fixtures has no urls file"
  fixtures=$(cd -- "$fixtures" && pwd)
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

if [ "${1:-}" = --one-action ]; then
  [ $# -eq 2 ] || die "--one-action needs ACTION-JSON"
  # Child of prs: work, RESULTS, WARNINGS come from the parent.
  one_action "$2"; exit $?
fi

cmd=${1:-}; [ $# -eq 0 ] || shift
sub=""
if [ "$cmd" = apply ]; then sub=${1:-}; [ $# -eq 0 ] || shift; fi
opt_image="" opt_upstream="" opt_lts=false opt_eol="" opt_succ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)      [ $# -ge 2 ] || die "--root needs a directory"; root=$(cd -- "$2" && pwd) || die "no directory $2"; shift 2 ;;
    --image)     [ $# -ge 2 ] || die "--image needs a name"; opt_image=$2; shift 2 ;;
    --upstream)  [ $# -ge 2 ] || die "--upstream needs a tag"; opt_upstream=$2; shift 2 ;;
    --lts)       [ $# -ge 2 ] || die "--lts needs true or false"; opt_lts=$2; shift 2 ;;
    --eol)       [ $# -ge 2 ] || die "--eol needs a date"; opt_eol=$2; shift 2 ;;
    --successor) [ $# -ge 2 ] || die "--successor needs an image"; opt_succ=$2; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -f "$root/.github/images.json" ] || die "$root has no .github/images.json"

case "$cmd" in
  plan)   WARNINGS="$tmp/warnings.txt"; NOTICES="$tmp/notices.txt"; plan ;;
  prs)    prs ;;
  render) render ;;
  members) members "$root/.github/images.json" ;;
  check)  rc=0; check || rc=$?; exit "$rc" ;;
  apply)
    [ -n "$opt_image" ] || die "apply needs --image"
    case "$sub" in
      add)       [ -n "$opt_upstream" ] || die "apply add needs --upstream"; apply_add "$opt_image" "$opt_upstream" "$opt_lts" ;;
      deprecate) [ -n "$opt_eol" ] || die "apply deprecate needs --eol"; apply_deprecate "$opt_image" "$opt_eol" "$opt_succ" ;;
      retire)    apply_retire "$opt_image" ;;
      *) die "apply add|deprecate|retire" ;;
    esac ;;
  ''|-h|--help) usage ;;
  *) die "unknown command: $cmd (see --help)" ;;
esac
