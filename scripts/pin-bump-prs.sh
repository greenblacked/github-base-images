#!/usr/bin/env bash
# Turn a check-pins.sh drift report into one pull request per unit -- the
# script behind .github/workflows/pin-bump.yml (docs/adr/0007-automatic-updates.md).
#
# For every unit that is behind (a tool, or a pin kept in several places):
#   1. branch `pin-bump/<unit>`, rebuilt from the base branch every time;
#   2. scripts/bump-pins.sh rewrites the version and its vendor checksums there;
#   3. one commit by github-actions[bot], pushed, and one PR opened or updated;
#   4. CI dispatched on the branch -- pushes made with the workflow token do not
#      trigger workflows, but a workflow_dispatch does, and its check runs land
#      on the branch head, which is what the required checks look at;
#   5. an `auto` bump gets auto-merge (squash), a `review` bump the
#      `needs-review` label and no auto-merge.
#
# Idempotent. A branch carrying a commit this workflow did not make -- by
# author or by committer -- is never touched: a human is working on it. An
# open PR already targeting the same version is not rebuilt, but it is healed:
# CI is dispatched again if its required checks never reported on the branch
# head, and an `auto` PR gets auto-merge if it is off and the ruleset now
# allows it. One targeting an older version gets its branch rebuilt and
# force-pushed (the branch belongs to this workflow) and its title and body
# rewritten. A PR a maintainer closed unmerged is not reopened for the same
# version.
#
# Units are processed one per child process, so a failure in one -- even one
# that trips errexit -- is recorded and the rest still run. The exit status is
# 1 if any unit errored, but only after all of them were processed.
#
# Environment:
#   DRIFT_FILE        check-pins.sh --format json report (required)
#   GITHUB_REPOSITORY owner/repo (required)
#   GH_TOKEN          for gh, and for git push/fetch via a credential helper
#                     that reads it from the environment at call time, so the
#                     token is never written to .git/config or the command line
#   BASE_BRANCH       default main
#   RUN_URL           linked from each PR body
#   DRY_RUN=1         run the local steps (worktree, bump, commit) and print --
#                     instead of running -- every command that would push,
#                     write to GitHub, or dispatch a workflow
#   PIN_BUMP_GH_STUB  directory of canned answers for the read-only gh queries
#                     (pr-<unit>.json, checks-<unit>.json, automerge-<unit>.json,
#                     rules.json, labels.json), for dry runs and the offline
#                     tests; <name>.exit, if present, is the query's exit status
#   PIN_BUMP_RESULTS  also write the per-unit results, one JSON object per
#                     line, to this file (the offline tests read it)
set -euo pipefail

readonly BOT_NAME='github-actions[bot]'
readonly BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
readonly LABEL=needs-review
# The checks the `main` ruleset requires (docs/security.md, "Required
# checks"). Auto-merge is only enabled when all of them are required: with
# fewer, "auto-merge once green" would mean green on less than the full gate.
readonly REQUIRED_CHECKS=("CI result" "Repository secret scan" "CodeQL (workflows)" "Dependency review")
# Which workflow reports each of those checks, for re-dispatching the one
# whose checks never ran.
readonly CHECK_WORKFLOWS=("CI result|build-and-push.yml" "Repository secret scan|security.yml"
  "CodeQL (workflows)|security.yml" "Dependency review|security.yml")
readonly SETTINGS_HELP="enable Settings -> General -> Pull Requests -> 'Allow auto-merge', and make the 'main' ruleset (Settings -> Rules -> Rulesets) require the status checks: CI result, Repository secret scan, CodeQL (workflows), Dependency review"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
base=${BASE_BRANCH:-main}
dry=${DRY_RUN:-}
stub=${PIN_BUMP_GH_STUB:-}
repo=${GITHUB_REPOSITORY:-}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 2; }

# Mutations: pushes, GitHub writes, dispatches. Printed, not run, in a dry run.
run() {
  if [ -n "$dry" ]; then
    printf 'DRY-RUN would run:' >&2; printf ' %q' "$@" >&2; printf '\n' >&2
    return 0
  fi
  "$@"
}
# Local, reversible steps: always run, and echoed so a dry run shows the whole
# sequence.
local_run() { printf '+' >&2; printf ' %q' "$@" >&2; printf '\n' >&2; "$@"; }

# Read-only GitHub queries, answerable from a stub directory.
gh_read() {
  local name="$1"; shift
  if [ -n "$stub" ]; then
    if [ -f "$stub/$name.json" ]; then cat "$stub/$name.json"; else echo '[]'; fi
    if [ -f "$stub/$name.exit" ]; then return "$(cat "$stub/$name.exit")"; fi
    return 0
  fi
  gh "$@"
}

# git over HTTPS with GH_TOKEN, via a credential helper that reads the token
# from the environment when git asks for it. Nothing is persisted, and the
# checkout step keeps persist-credentials: false.
git_net() {
  # The single quotes are deliberate: $GH_TOKEN is expanded by the helper's
  # own shell when git calls it, not here. Called through run/local_run,
  # which shellcheck cannot follow (SC2317).
  # shellcheck disable=SC2016,SC2317
  git -c credential.helper= \
      -c 'credential.helper=!f() { echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f' "$@"
}

# ---------------------------------------------------------------------------
# One unit, in its own process (see the header for why).
# ---------------------------------------------------------------------------
one_unit() {
  local unit="$1" to="$2" old="$3"
  local branch="pin-bump/$unit" wt="$work/wt-$unit"
  local remote_sha pr_all open_json pr_num="" pr_url="" prev_to="" prev_class="" closed_same marker
  local action="" class="" new="" note="" errors=""

  row() { # STATUS ACTION -- one result line for the summary
    jq -nc --arg unit "$unit" --arg old "$old" --arg new "${new:-$to}" --arg class "$class" \
      --arg pr "$pr_url" --arg status "$1" --arg action "$2" --arg note "$note" \
      '{unit:$unit, old:$old, new:$new, class:$class, pr:$pr, status:$status, action:$action, note:$note}' \
      >> "$RESULTS"
  }

  remote_sha=$(git rev-parse -q --verify "refs/remotes/origin/$branch" || true)
  pr_all=$(gh_read "pr-$unit" pr list --repo "$repo" --head "$branch" --base "$base" --state all \
            --limit 50 --json number,state,url,body,headRefName,isCrossRepository,labels)
  # Same-named branches on forks are not ours.
  pr_all=$(jq -c --arg b "$branch" '[.[] | select(.headRefName == $b and (.isCrossRepository | not))]' <<<"$pr_all")
  open_json=$(jq -c '[.[] | select(.state == "OPEN")][0] // empty' <<<"$pr_all")
  if [ -n "$open_json" ]; then
    pr_num=$(jq -r .number <<<"$open_json"); pr_url=$(jq -r .url <<<"$open_json")
    marker=$(jq -r '.body // ""' <<<"$open_json" \
      | grep -oE '<!-- pin-bump: unit=[^ ]+ to=[^ ]+( class=[^ ]+)? -->' | head -1 || true)
    prev_to=$(sed -nE 's/.* to=([^ ]+)( class=[^ ]+)? -->/\1/p' <<<"$marker")
    prev_class=$(sed -nE 's/.* class=([^ ]+) -->/\1/p' <<<"$marker")
  fi
  closed_same=$(jq -r --arg to "$to" \
    '[.[] | select(.state == "CLOSED" and ((.body // "") | (contains("to=" + $to + " -->") or contains("to=" + $to + " class="))))][0].url // empty' \
    <<<"$pr_all")

  if [ -z "$open_json" ] && [ -n "$closed_same" ]; then
    row skipped "not reopened: $closed_same was closed unmerged for this version"
    return 0
  fi

  # A commit on the branch that this workflow did not make means a human is
  # working there: leave the branch alone, and do not heal it either --
  # enabling auto-merge would merge their commit unreviewed. Author AND
  # committer: an amend or rebase by a maintainer keeps the bot as author, and
  # GitHub's "Update branch" adds a merge commit authored by whoever clicked
  # it. Read with the rc idiom, because a git log that failed would otherwise
  # look like a branch with nothing foreign on it.
  if [ -n "$remote_sha" ]; then
    local emails rc=0 foreign
    emails=$(git log --format='%ae%n%ce' "origin/$base..$remote_sha") || rc=$?
    if [ "$rc" -ne 0 ]; then
      note="could not list the commits on $branch (git log exit $rc)"
      row error "none"
      return 1
    fi
    foreign=$(printf '%s\n' "$emails" | grep -vxF "$BOT_EMAIL" | grep -v '^$' | sort -u | paste -sd, - || true)
    if [ -n "$foreign" ]; then
      note="commits by $foreign. If the newest is GitHub's 'Update branch' merge, drop it so the weekly run can take the branch back: git fetch origin && git push --force-with-lease origin origin/$branch^1:refs/heads/$branch (see docs/pipeline.md, Automatic updates)"
      row skipped "$branch has commits not made by this workflow; left for their author${pr_num:+ (#$pr_num)}"
      return 0
    fi
  fi

  if [ -n "$open_json" ] && [ "$prev_to" = "$to" ]; then
    if [ -n "$remote_sha" ] && git merge-base --is-ancestor "origin/$base" "$remote_sha"; then
      heal "$remote_sha"
      return $?
    fi
    # Same version, but the branch is behind the base. With "require branches
    # to be up to date" on, it could never merge, and doing nothing would
    # leave it stuck forever; so it is rebuilt like an outdated one.
    note="rebuilt because the branch was behind $base. "
  fi
  # --- rebuild the branch from the base, in a throwaway worktree.
  rm -rf "$wt"
  local_run git worktree add --quiet --detach "$wt" "origin/$base"
  local rc=0 result
  "$script_dir/bump-pins.sh" --root "$wt" --unit "$unit" --to "$to" --format json --quiet \
    > "$work/bump-$unit.json" 2> "$work/bump-$unit.err" || rc=$?
  result=$(jq -c '.[0] // empty' "$work/bump-$unit.json" 2>/dev/null || true)
  if [ -z "$result" ]; then
    note="bump-pins exit $rc: $(tail -3 "$work/bump-$unit.err" | tr '\n' ' ')"
    row error "bump failed"
    return 1
  fi
  old=$(jq -r '.old // ""' <<<"$result"); new=$(jq -r '.new // ""' <<<"$result")
  class=$(jq -r '.class // ""' <<<"$result")
  case "$(jq -r .status <<<"$result")" in
    bumped) ;;
    deferred) note=$(jq -r .reason <<<"$result"); row deferred "none: inside the cooldown"; return 0 ;;
    current)  row current "none: $base is already at $new"; return 0 ;;
    *)        note=$(jq -r '.error // "unknown"' <<<"$result"); row error "bump failed"; return 1 ;;
  esac

  local reason files urls version_url released title
  reason=$(jq -r .reason <<<"$result")
  files=$(jq -r '.files | join(", ")' <<<"$result")
  urls=$(jq -r '.integrity_urls | map("- " + .) | join("\n")' <<<"$result")
  version_url=$(jq -r '.version_url // ""' <<<"$result")
  released=$(jq -r 'if .released then "released " + .released else "release date not established" end' <<<"$result")
  title="Bump $unit from $old to $new"

  local_run git -C "$wt" add -u
  printf '%s\n\n%s\n\nClassification: %s (%s)\nChecksum source:\n%s\n' \
    "$title" "Rewritten by scripts/bump-pins.sh from the vendor's published checksums or registry record." \
    "$class" "$reason" "${urls:-  (none published)}" > "$work/msg-$unit"
  local_run env GIT_AUTHOR_NAME="$BOT_NAME" GIT_AUTHOR_EMAIL="$BOT_EMAIL" \
    GIT_COMMITTER_NAME="$BOT_NAME" GIT_COMMITTER_EMAIL="$BOT_EMAIL" \
    git -C "$wt" commit --quiet --file "$work/msg-$unit"

  {
    echo "Automated bump of a hand-pinned tool, opened by the weekly pin-bump workflow."
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Tool | \`$unit\` |"
    echo "| Version | \`$old\` → \`$new\` |"
    echo "| Files | $files |"
    echo "| Release | $version_url ($released) |"
    echo "| Classification | **$class**: $reason |"
    echo
    echo "Checksum or integrity source (the vendor's own file for this version; nothing was computed from a download):"
    echo
    if [ -n "$urls" ]; then echo "$urls"; else echo "- none published: this download is not checksum-verified"; fi
    echo
    if [ "$class" = auto ]; then
      echo "This PR **merges itself** (squash) once every required check passes. It will not merge red."
    else
      echo "Labelled \`$LABEL\`: auto-merge is **off**. A maintainer merges this after reading the release notes."
    fi
    echo
    echo "CI was started by dispatching *Build and Push to GHCR* and *Security* on this branch, since a push"
    echo "made with the workflow token triggers no workflow. The dispatched build rebuilds every image, not"
    echo "only the one this bump touches. After merge the image publishes with the next weekly rebuild"
    echo "(docs/adr/0007-automatic-updates.md)."
    echo
    echo "Please do not use *Update branch* here: the weekly run rebuilds a branch that fell behind \`$base\`,"
    echo "but it never force-pushes over a commit it did not make, so that merge commit leaves this PR to you"
    echo "(docs/pipeline.md, *Automatic updates*, says how to hand it back)."
    echo
    [ -n "${RUN_URL:-}" ] && { echo "Run: $RUN_URL"; echo; }
    # Read back by the next run: the version this PR targets, and its class,
    # which the heal path needs without re-running the bump.
    echo "<!-- pin-bump: unit=$unit to=$new class=$class -->"
  } > "$work/body-$unit.md"

  if [ -n "$dry" ]; then
    git -C "$wt" show --stat --format='commit by %an <%ae>, committer %cn <%ce>%n%n%B' HEAD >&2
    git -C "$wt" show --format= --unified=0 HEAD >&2
    sed 's/^/  | /' "$work/body-$unit.md" >&2
  fi

  # --force-with-lease pinned to the SHA this run saw (or to "absent"): if
  # anything moved the branch since the fetch, the push fails rather than
  # overwriting it.
  rc=0
  run git_net -C "$wt" push --quiet --force-with-lease="refs/heads/$branch:$remote_sha" \
    origin "HEAD:refs/heads/$branch" || rc=$?
  if [ "$rc" -ne 0 ]; then
    note="${note}push refused (exit $rc): $branch moved since this run fetched it, or the push was not allowed"
    row error "none"
    return 1
  fi

  if [ -n "$pr_num" ]; then
    run gh pr edit "$pr_num" --repo "$repo" --title "$title" --body-file "$work/body-$unit.md"
    action="updated #$pr_num (was ${prev_to:-unknown})"
  else
    if [ -n "$dry" ]; then
      run gh pr create --repo "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$work/body-$unit.md"
      pr_url="(dry run)"; pr_num='<new>'
    else
      pr_url=$(gh pr create --repo "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$work/body-$unit.md")
      pr_num=${pr_url##*/}
    fi
    action="opened"
  fi

  dispatch build-and-push.yml security.yml

  if [ "$class" = auto ]; then
    if [ -n "$open_json" ] && jq -e --arg l "$LABEL" 'any(.labels[]?; .name == $l)' <<<"$open_json" >/dev/null; then
      # It was a review bump before, and the new version is not.
      rc=0; run gh pr edit "$pr_num" --repo "$repo" --remove-label "$LABEL" || rc=$?
    fi
    enable_automerge
  else
    ensure_label || { note="${note}could not create or find the $LABEL label"; row error "$action"; return 1; }
    run gh pr edit "$pr_num" --repo "$repo" --add-label "$LABEL"
    if [ -n "$open_json" ]; then
      # A previous version of this PR may have been auto. Fails harmlessly
      # when auto-merge was never on.
      rc=0; run gh pr merge "$pr_num" --repo "$repo" --disable-auto || rc=$?
    fi
    action="$action, labelled $LABEL"
  fi

  finish
}

# The helpers below run inside one_unit and share its locals (unit, branch,
# pr_num, class, action, note, errors) through bash's dynamic scoping.

# Start CI on the branch. A failed dispatch is the unit's error, not a
# warning: the PR would wait for checks that never start. The other workflow
# is still dispatched, and the rest of the unit still runs; the next run's
# heal re-dispatches whatever never reported.
dispatch() { # WORKFLOW...
  local wf rc
  for wf in "$@"; do
    rc=0; run gh workflow run "$wf" --repo "$repo" --ref "$branch" || rc=$?
    if [ "$rc" -eq 0 ]; then
      action="$action, $wf dispatched"
    else
      errors="${errors}gh workflow run $wf failed (exit $rc). "
    fi
  done
}

# Auto-merge for an `auto` unit, but only when the ruleset makes "once green"
# mean the full gate.
enable_automerge() {
  local rc
  if [ -n "$AUTOMERGE_BLOCKER" ]; then
    note="${note}auto-merge not enabled: $AUTOMERGE_BLOCKER"
    action="$action, left open (see warnings)"
    return 0
  fi
  rc=0; run gh pr merge "$pr_num" --repo "$repo" --auto --squash || rc=$?
  if [ "$rc" -eq 0 ]; then
    action="$action, auto-merge on"
  else
    note="${note}gh pr merge --auto failed (exit $rc); to fix: $SETTINGS_HELP"
    action="$action, left open (see warnings)"
  fi
}

# Workflows among CHECK_WORKFLOWS with a required check that has no usable
# check run on SHA, space-separated. A run in any state but cancelled counts as
# present: a red one is a result for a human to read, and re-dispatching it
# every week would only burn an hour of runners each time. A cancelled one has
# no result and would hold the PR forever, so it counts as missing. Fails when
# the check runs cannot be read, so an API error never reads as "all present".
ci_missing() { # SHA
  local sha="$1" pair c wf out rc missing=""
  for pair in "${CHECK_WORKFLOWS[@]}"; do
    c=${pair%%|*}; wf=${pair#*|}
    case " $missing " in *" $wf "*) continue ;; esac
    rc=0
    out=$(gh_read "checks-$unit" api \
      "repos/$repo/commits/$sha/check-runs?check_name=$(jq -rn --arg c "$c" '$c | @uri')&per_page=100") || rc=$?
    if [ "$rc" -ne 0 ] || ! jq -e '.check_runs | type == "array"' <<<"$out" >/dev/null 2>&1; then
      log "could not read the check runs on $sha (exit $rc)"
      return 1
    fi
    # The name is filtered again here, so a stub may answer every query with
    # the commit's full list.
    jq -e --arg c "$c" 'any(.check_runs[]; .name == $c and .conclusion != "cancelled")' <<<"$out" >/dev/null || missing="$missing $wf"
  done
  printf '%s' "${missing# }"
}

# An open PR already at the target version, on a branch that is up to date:
# nothing to rebuild, but whatever the run that opened it failed to do is done
# now. Without this a one-off dispatch failure, or auto-merge refused before
# the settings were in place, would leave the PR stuck until the next version.
heal() { # HEAD_SHA
  local sha="$1" missing rc am
  class=$prev_class
  action="#$pr_num already targets $to"

  rc=0; missing=$(ci_missing "$sha") || rc=$?
  if [ "$rc" -ne 0 ]; then
    errors="${errors}could not read the check runs on ${sha:0:12}, so CI was neither confirmed nor re-dispatched. "
  elif [ -n "$missing" ]; then
    action="$action; checks missing on ${sha:0:12}"
    # Word splitting is the point: one workflow file per word.
    # shellcheck disable=SC2086
    dispatch $missing
  else
    action="$action; checks present on ${sha:0:12}"
  fi

  case "$class" in
    auto)
      rc=0; am=$(gh_read "automerge-$unit" pr view "$pr_num" --repo "$repo" --json autoMergeRequest) || rc=$?
      if [ "$rc" -ne 0 ] || ! jq -e 'type == "object" and has("autoMergeRequest")' <<<"$am" >/dev/null 2>&1; then
        errors="${errors}could not read whether auto-merge is on for #$pr_num (exit $rc). "
      elif jq -e '.autoMergeRequest != null' <<<"$am" >/dev/null; then
        action="$action, auto-merge already on"
      else
        enable_automerge
      fi ;;
    review) ;;
    *) note="${note}the PR body records no class, so auto-merge was left as it is. " ;;
  esac
  finish unchanged
}

# Record the unit's row: an error if anything above failed, else STATUS.
finish() { # [STATUS]
  note="${errors}${note}"; note=${note% }
  if [ -n "$errors" ]; then
    row error "$action"
    return 1
  fi
  row "${1:-ok}" "$action"
}

# Create the label if missing. `gh label create` fails when it exists, so a
# failure is followed by a look: only a label that is really there counts.
ensure_label() {
  local rc=0
  run gh label create "$LABEL" --repo "$repo" --color d93f0b \
    --description "Automated update that a maintainer must review and merge" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  gh_read labels label list --repo "$repo" --search "$LABEL" --json name \
    | jq -e --arg l "$LABEL" 'any(.[]; .name == $l)' >/dev/null
}

# ---------------------------------------------------------------------------
if [ "${1:-}" = --one-unit ]; then
  # Child mode: environment (work, RESULTS, AUTOMERGE_BLOCKER, ...) is
  # inherited from the parent below.
  [ $# -eq 4 ] || die "--one-unit needs UNIT VERSION PINNED"
  one_unit "$2" "$3" "$4"
  exit $?
fi

if [ -z "${DRIFT_FILE:-}" ] || [ ! -f "$DRIFT_FILE" ]; then
  die "DRIFT_FILE must name a check-pins.sh --format json report"
fi
[ -n "$repo" ] || die "GITHUB_REPOSITORY is required"
if [ -z "$stub" ]; then command -v gh >/dev/null || die "gh not found"; fi
for cmd in git jq; do command -v "$cmd" >/dev/null || die "$cmd not found"; done
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "the checkout has uncommitted changes"

work=$(mktemp -d)
# Removing the directory and pruning is what `git worktree remove` does for
# each one, and covers a worktree left behind by a child that died. Inlined
# rather than a function, which shellcheck flags as unreachable (SC2317).
trap 'rm -rf "$work"; git worktree prune' EXIT INT TERM
RESULTS="$work/results.jsonl"; : > "$RESULTS"
export work RESULTS

# Every remote branch this might touch, fresh: the lease below is only as good
# as the SHA it was taken from.
local_run git_net fetch --quiet --no-tags --prune origin \
  "+refs/heads/$base:refs/remotes/origin/$base" \
  "+refs/heads/pin-bump/*:refs/remotes/origin/pin-bump/*"

# Auto-merge is only as safe as what it waits for. Read which checks the
# base branch's rulesets actually require, and enable auto-merge only if the
# full gate is among them; otherwise say exactly what is missing.
AUTOMERGE_BLOCKER=""
rc=0
rules=$(gh_read rules api "repos/$repo/rules/branches/$base") || rc=$?
if [ "$rc" -ne 0 ] || ! jq -e 'type == "array"' <<<"$rules" >/dev/null 2>&1; then
  AUTOMERGE_BLOCKER="the rules for $base could not be read (exit $rc), so the required checks are unknown"
else
  missing=()
  for c in "${REQUIRED_CHECKS[@]}"; do
    jq -e --arg c "$c" 'any(.[]; .type == "required_status_checks" and any(.parameters.required_status_checks[]?; .context == $c))' \
      <<<"$rules" >/dev/null || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    joined=$(printf '%s, ' "${missing[@]}")
    AUTOMERGE_BLOCKER="the $base ruleset does not require: ${joined%, }"
  fi
fi
export AUTOMERGE_BLOCKER

# Tools the checker could not resolve are errors here too: not bumping them
# is right, not saying so would be a check that passed without looking.
jq -c '.tools[] | select(.state == "unresolved")
       | {unit:.tool, old:.pinned, new:"", class:"", pr:"", status:"error",
          action:"none", note:"check-pins could not resolve the vendor version"}' "$DRIFT_FILE" >> "$RESULTS"

rc=0
"$script_dir/bump-pins.sh" --plan --drift "$DRIFT_FILE" > "$work/plan.jsonl" 2> "$work/plan.err" || rc=$?
jq -c 'select(.status == "error") | {unit, old:"", new:(.new // ""), class:"", pr:"", status:"error", action:"none", note:.error}' \
  "$work/plan.jsonl" >> "$RESULTS"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  log "error: bump-pins --plan failed (exit $rc)"; cat "$work/plan.err" >&2; exit 1
fi

while IFS=$'\t' read -r unit to from; do
  log ""
  log "== $unit -> $to"
  before=$(wc -l < "$RESULTS")
  rc=0
  "$BASH" "$0" --one-unit "$unit" "$to" "$from" || rc=$?
  if [ "$(wc -l < "$RESULTS")" -eq "$before" ]; then
    # The child died before recording anything: record it for it.
    jq -nc --arg u "$unit" --arg to "$to" --arg from "$from" --arg rc "$rc" \
      '{unit:$u, old:$from, new:$to, class:"", pr:"", status:"error", action:"none", note:("aborted, exit " + $rc)}' >> "$RESULTS"
  fi
done < <(jq -r 'select(.to) | [.unit, .to, .from] | @tsv' "$work/plan.jsonl")

# --- summary ---------------------------------------------------------------
{
  echo "### Pin bumps${dry:+ (dry run)}"
  echo
  if [ "$(wc -l < "$RESULTS")" -eq 0 ]; then
    echo "Every pinned tool is current. Nothing to do."
  else
    echo "| tool | old | new | class | PR | action |"
    echo "|---|---|---|---|---|---|"
    jq -r '"| \(.unit) | \(if .old == "" then "—" else "`" + .old + "`" end) | \(if .new == "" then "—" else "`" + .new + "`" end) | \(if .class == "" then "—" else .class end) | \(if .pr == "" then "—" else .pr end) | \(if .status == "error" then "**error**: " else "" end)\(.action)\(if .note != "" then " — " + .note else "" end) |"' "$RESULTS"
  fi
  if jq -se 'any(.[]; .note | contains("auto-merge not enabled"))' "$RESULTS" >/dev/null; then
    echo
    echo "> **Warning:** auto-merge was not enabled, because $AUTOMERGE_BLOCKER. Those PRs are open and waiting."
    echo "> To let them merge themselves: $SETTINGS_HELP."
  fi
} > "$work/summary.md"
[ -z "${PIN_BUMP_RESULTS:-}" ] || cp "$RESULTS" "$PIN_BUMP_RESULTS"
# Into the job summary when there is one, and into the log either way.
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$work/summary.md" >> "$GITHUB_STEP_SUMMARY"
cat "$work/summary.md"

# Annotations, so a PR left open for want of a setting is visible on the run
# page and not only in the summary.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  jq -r 'select(.note | test("auto-merge")) | "::warning::\(.unit): \(.note)"' "$RESULTS"
  jq -r 'select(.status == "error") | "::error::\(.unit): \(.note)"' "$RESULTS"
fi

errors=$(jq -s '[.[] | select(.status == "error")] | length' "$RESULTS")
if [ "$errors" -gt 0 ]; then
  log "error: $errors unit(s) failed; see the summary"
  exit 1
fi
exit 0
