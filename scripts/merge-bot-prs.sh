#!/usr/bin/env bash
# Merge the automated update pull requests once they are green -- the script
# behind .github/workflows/merge-bot-prs.yml (docs/adr/0008-self-updating.md).
#
# Why this exists: the images are only useful to their consumers if they stay
# current without anyone tending them, and the updates already arrive as pull
# requests (Dependabot; scripts/pin-bump-prs.sh) that run the full build,
# smoke tests and vulnerability gate. What was missing was the last step. It
# used to be GitHub auto-merge, which is only as strict as the `main` ruleset
# it waits on -- with no active ruleset it merges at once, checks or not -- and
# which needs a repository setting nothing here can turn on. This script reads
# the four checks itself, on the PR's exact head commit, and merges only what
# passed them. It depends on no ruleset and no repository setting.
#
# Candidates: open pull requests into BASE_BRANCH (main), from a branch in
# this repository (never a fork), that are either
#   - dependabot/*, opened by dependabot[bot], or
#   - pin-bump/*,   opened by github-actions[bot] (scripts/pin-bump-prs.sh).
# Every other open PR is counted and left alone.
#
# For each candidate, in order:
#   1. `hold` label: never merged, nothing else done. The kill switch.
#   2. Every commit on the PR must be the bot's own, by author AND committer,
#      as GitHub records them (login and email), or the PR is left alone: a
#      human is working on it, and merging would merge their commit
#      unreviewed. What "the bot's own" means is spelled out at own_commits.
#   3. The four required checks -- CI result, Repository secret scan, CodeQL
#      (workflows), Dependency review -- each read on the PR's current head
#      SHA. For each name, the latest check run from GitHub Actions counts. All
#      four completed with conclusion success: green. Anything else is not:
#      missing, queued, in progress, skipped, neutral, cancelled, failed, or a
#      check-run list that could not be read. Only red and unreadable are
#      warnings; the rest is waiting.
#   4. Green and mergeable (no conflict): `gh pr merge --squash
#      --match-head-commit <sha>`, so a push between the check and the merge
#      makes GitHub refuse the merge instead of merging unchecked commits.
#   5. Red, Dependabot, and the branch is behind main: the red result may be
#      main's old fault rather than the update's (a gate since fixed on main,
#      say), and Dependabot rebases only on a conflict, so nothing would ever
#      re-test it. So, at most once per (PR, main commit): a marker comment
#      recording the branch head and main, then GitHub's update-branch
#      (merge main in, leased to the head SHA that was read), then CI
#      dispatched on the branch. Never for pin-bump/*: pin-bump-prs.sh
#      rebuilds those from main itself, and a merge commit on one would make
#      it hands-off for good.
# After the loop, if anything merged: dispatch build-and-push.yml and
# security.yml on main, once. A merge made with the workflow token starts no
# push workflow, so without this the update would publish only with the next
# daily rebuild.
#
# Why a comment, not a label, records the refresh: it has to carry two SHAs
# (which head, against which main), and the commit check in step 2 must be
# able to tell the merge commit update-branch made from one anybody else made.
# A comment holds both, and its author is recorded by GitHub, so only a
# comment by github-actions[bot] counts as a marker. A label could hold
# neither. Being written BEFORE the update, it also bounds retries: a refresh
# that fails is not attempted again until main moves.
#
# Exit status: 1 if anything this run tried to do failed -- a merge, a
# comment, an update, a dispatch -- or the PR list could not be read, after
# every PR was processed. 0 otherwise, including when PRs are red or waiting:
# those are states, reported per PR, not failures of this job.
#
# Environment:
#   GITHUB_REPOSITORY  owner/repo (required)
#   GH_TOKEN           for gh
#   BASE_BRANCH        default main
#   DRY_RUN=1          read everything, print every write instead of making it
#   RUN_URL            linked from the marker comment
#   MERGE_BOT_GH_STUB  directory of canned answers for the read-only queries
#                      (main.json, prs.json, pr-<n>.json, commits-<n>.json,
#                      checks-<n>.json, compare-<n>.json, comments-<n>.json,
#                      head-<n>.json), for the offline tests; a missing file is
#                      a failed read, and <name>.exit, if present, is the
#                      query's exit status
#   MERGE_BOT_RESULTS  also write the per-PR results, one JSON object per
#                      line, to this file (the offline tests read it)
#   MERGE_BOT_POLL_ATTEMPTS, MERGE_BOT_POLL_DELAY
#                      how long to wait for update-branch to move the branch
#                      before dispatching CI on it (default 12 x 5s)
set -euo pipefail

readonly DEP_LOGIN='dependabot[bot]'
readonly DEP_EMAIL='49699333+dependabot[bot]@users.noreply.github.com'
readonly GHA_LOGIN='github-actions[bot]'
readonly GHA_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
readonly WEBFLOW_LOGIN='web-flow'
readonly WEBFLOW_EMAIL='noreply@github.com'
readonly HOLD=hold
# Which workflow reports each required check (docs/security.md, "Required
# checks"), for dispatching the ones a refreshed branch needs.
readonly CHECK_WORKFLOWS=("CI result|build-and-push.yml" "Repository secret scan|security.yml"
  "CodeQL (workflows)|security.yml" "Dependency review|security.yml")

base=${BASE_BRANCH:-main}
dry=${DRY_RUN:-}
stub=${MERGE_BOT_GH_STUB:-}
repo=${GITHUB_REPOSITORY:-}
poll_attempts=${MERGE_BOT_POLL_ATTEMPTS:-12}
poll_delay=${MERGE_BOT_POLL_DELAY:-5}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 2; }

# Writes: merges, comments, branch updates, dispatches. Printed, not run, in a
# dry run.
run() {
  if [ -n "$dry" ]; then
    printf 'DRY-RUN would run:' >&2; printf ' %q' "$@" >&2; printf '\n' >&2
    return 0
  fi
  "$@"
}

# Read-only GitHub queries, answerable from a stub directory. A stub that has
# no file for a query fails it: a test that forgot a read must not see an
# empty answer that happens to look like a clean one.
gh_read() {
  local name="$1"; shift
  if [ -n "$stub" ]; then
    [ -f "$stub/$name.json" ] || return 1
    cat "$stub/$name.json"
    if [ -f "$stub/$name.exit" ]; then return "$(cat "$stub/$name.exit")"; fi
    return 0
  fi
  gh "$@"
}

# ---------------------------------------------------------------------------
# One PR, in its own process: a failure that trips errexit in one is recorded
# for it, and the rest still run. (A subshell on the left of `||` would run
# with errexit silently off, which is the opposite of what is wanted.)
# ---------------------------------------------------------------------------
one_pr() {
  local n="$1"
  local pr kind ref sha="" detail commits comments markers foreign
  local note="" rc

  pr=$(jq -c --argjson n "$n" '.[] | select(.number == $n)' "$work/prs.json")
  ref=$(jq -r '.head.ref' <<<"$pr")
  kind=$(jq -r 'if (.head.ref | startswith("dependabot/")) then "dependabot" else "pin-bump" end' <<<"$pr")

  row() { # STATUS ACTION -- one result line for the summary
    jq -nc --argjson pr "$n" --arg kind "$kind" --arg ref "$ref" --arg head "${sha:0:12}" \
      --arg status "$1" --arg action "$2" --arg note "$note" \
      '{pr:$pr, kind:$kind, branch:$ref, head:$head, status:$status, action:$action, note:$note}' >> "$RESULTS"
  }

  if jq -e --arg l "$HOLD" 'any(.labels[]?; .name == $l)' <<<"$pr" >/dev/null; then
    sha=$(jq -r '.head.sha' <<<"$pr")
    row held "not merged: labelled \`$HOLD\`"
    return 0
  fi

  # The PR itself, fresh: the head SHA everything below is checked against,
  # how many commits it has, and whether it merges cleanly.
  rc=0; detail=$(gh_read "pr-$n" api "repos/$repo/pulls/$n") || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e --argjson n "$n" '.number == $n and .state == "open"
        and (.head.sha | type == "string" and test("^[0-9a-f]{40}$"))
        and (.commits | type == "number")' <<<"$detail" >/dev/null 2>&1; then
    note="the pull request could not be read (exit $rc)"
    row unreadable "not merged"
    return 0
  fi
  sha=$(jq -r '.head.sha' <<<"$detail")
  if jq -e '.draft == true' <<<"$detail" >/dev/null; then
    row waiting "not merged: draft"
    return 0
  fi

  # Every commit on the branch. Read whole -- the count must match the PR's,
  # and the last one must be the head -- or not trusted at all.
  rc=0; commits=$(gh_read "commits-$n" api --paginate "repos/$repo/pulls/$n/commits?per_page=100") || rc=$?
  if [ "$rc" -eq 0 ]; then
    commits=$(jq -sc 'if length > 0 and all(.[]; type == "array") then add else error("not one or more arrays") end' <<<"$commits" 2>/dev/null) || rc=1
  fi
  if [ "$rc" -ne 0 ] || ! jq -e --argjson count "$(jq .commits <<<"$detail")" --arg sha "$sha" \
        'length == $count and length > 0 and .[-1].sha == $sha
         and all(.[]; type == "object" and (.parents | type) == "array" and (.commit | type) == "object")' \
        <<<"$commits" >/dev/null 2>&1; then
    note="the commit list could not be read whole (exit $rc), so the branch's authorship is unknown"
    row unreadable "not merged"
    return 0
  fi

  # Refresh markers: comments by github-actions[bot] itself (GitHub records
  # the author; anyone can write the same text). Only Dependabot PRs can have
  # any, and only they need them.
  markers='[]'
  if [ "$kind" = dependabot ]; then
    rc=0; comments=$(gh_read "comments-$n" api --paginate "repos/$repo/issues/$n/comments?per_page=100") || rc=$?
    if [ "$rc" -eq 0 ]; then
      markers=$(jq -sc --arg gha "$GHA_LOGIN" '
        if length > 0 and all(.[]; type == "array") then add else error("not one or more arrays") end
        | [ .[] | select(.user.login == $gha and .user.type == "Bot") | (.body // "")
            | capture("<!-- merge-bot: refresh head=(?<head>[0-9a-f]{40}) main=(?<main>[0-9a-f]{40}) -->"; "g") ]' \
        <<<"$comments" 2>/dev/null) || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
      note="its comments could not be read (exit $rc), so a refresh merge commit cannot be told from anyone else's"
      row unreadable "not merged"
      return 0
    fi
  fi

  foreign=$(own_commits "$kind" "$markers" <<<"$commits")
  if [ -n "$foreign" ]; then
    note="commits not made by the bot: $foreign"
    row skipped "left alone: someone else has committed to $ref"
    return 0
  fi

  # The four checks, on this exact SHA.
  local pair c out st states="" red="" waiting="" unreadable="" missing_wf=""
  for pair in "${CHECK_WORKFLOWS[@]}"; do
    c=${pair%%|*}
    rc=0
    out=$(gh_read "checks-$n" api \
      "repos/$repo/commits/$sha/check-runs?check_name=$(jq -rn --arg c "$c" '$c | @uri')&filter=all&per_page=100") || rc=$?
    # Filtered by name again here, so a stub may answer every query with the
    # commit's whole list. A page that does not hold every run (total_count
    # says more exist) could be missing the latest one, so it is unreadable
    # too. Only GitHub Actions' runs count: another app cannot report a
    # "CI result" that merges a PR.
    st=$( { [ "$rc" -eq 0 ] && jq -r --arg c "$c" '
        if (.check_runs | type) != "array" then error("no check_runs") else . end
        | [.check_runs[] | select(.name == $c)] as $named
        | if (.total_count // (.check_runs | length)) > (.check_runs | length) then "unreadable"
          else ($named | map(select(.app.slug == "github-actions")) | max_by(.id)) as $r
            | if $r == null then "missing"
              elif $r.status != "completed" then $r.status
              else ($r.conclusion // "none") end
          end' <<<"$out"; } 2>/dev/null) || st=unreadable
    states="${states}${states:+, }$c: $st"
    case "$st" in
      success) ;;
      failure|timed_out|startup_failure|cancelled|action_required) red="${red}${red:+, }$c ($st)" ;;
      unreadable) unreadable="${unreadable}${unreadable:+, }$c" ;;
      missing) waiting="${waiting}${waiting:+, }$c (missing)"
               case " $missing_wf " in *" ${pair#*|} "*) ;; *) missing_wf="$missing_wf ${pair#*|}" ;; esac ;;
      *) waiting="${waiting}${waiting:+, }$c ($st)" ;;
    esac
  done

  if [ -n "$unreadable" ]; then
    note="could not read the check runs for: $unreadable"
    row unreadable "not merged"
    return 0
  fi

  if [ -n "$red" ]; then
    note="failed on ${sha:0:12}: $red"
    if [ "$kind" = dependabot ]; then
      refresh "$n" "$markers"
      return $?
    fi
    row red "not merged; pin-bump.yml rebuilds the branch from $base when main or the vendor moves"
    return 0
  fi

  if [ -n "$waiting" ]; then
    # A Dependabot branch this workflow brought up to date, whose CI never
    # started (the update landed after the run that made it stopped
    # waiting, or a dispatch failed): start it. Only on that merge commit,
    # so an ordinary PR whose checks are still queued is left to them.
    if [ "$kind" = dependabot ] && [ -n "$missing_wf" ] && head_is_refresh "$markers" <<<"$commits"; then
      note="checks never started on the refresh merge ${sha:0:12}: $waiting"
      # shellcheck disable=SC2086  # one workflow file per word
      if dispatch_on "$ref" $missing_wf; then
        row refreshed "CI dispatched on $ref:$missing_wf"
        return 0
      fi
      row error "dispatch on $ref failed"
      return 1
    fi
    note="$waiting"
    row waiting "not merged: checks not all green yet"
    return 0
  fi

  # Green. Mergeable is a three-state answer: true, false (a conflict), or
  # null (GitHub has not computed it yet). Only true merges.
  case "$(jq -r '.mergeable' <<<"$detail")" in
    true) ;;
    false) note="merge conflict with $base; Dependabot rebases its own branches, pin-bump.yml rebuilds its own"
           row waiting "not merged: conflicts with $base"; return 0 ;;
    *) row waiting "not merged: GitHub has not worked out whether it merges cleanly yet"; return 0 ;;
  esac

  note="all four checks passed on ${sha:0:12}"
  rc=0; run gh pr merge "$n" --repo "$repo" --squash --match-head-commit "$sha" || rc=$?
  if [ "$rc" -ne 0 ]; then
    note="gh pr merge exited $rc. The head may have moved since it was checked (then the next run looks again), or the merge was refused"
    row error "merge failed"
    return 1
  fi
  row merged "merged (squash) at ${sha:0:12}"
}

# Reads the PR's commits on stdin; prints one description per commit that is
# not the bot's own, comma-separated (empty when all are). KIND MARKERS-JSON
#
#   pin-bump:   author and committer both github-actions[bot], by login and
#               email, one parent. scripts/pin-bump-prs.sh makes exactly one
#               such commit and never a merge.
#   dependabot: either Dependabot's own commit -- author dependabot[bot],
#               committer GitHub's web-flow, verified signature, one parent:
#               that is how Dependabot's commits are recorded, checked
#               against the live API -- or a merge commit this workflow's
#               update-branch made: author github-actions[bot], committer
#               web-flow or github-actions[bot], and its two parents exactly
#               the head and main recorded in one of this workflow's marker
#               comments. Nothing else: not a maintainer's commit, not
#               GitHub's "Update branch" clicked by a person (authored by
#               them), not a merge commit no marker accounts for.
own_commits() {
  jq -r --arg kind "$1" --argjson markers "$2" \
    --arg dep "$DEP_LOGIN" --arg dep_email "$DEP_EMAIL" \
    --arg gha "$GHA_LOGIN" --arg gha_email "$GHA_EMAIL" \
    --arg wf "$WEBFLOW_LOGIN" --arg wf_email "$WEBFLOW_EMAIL" '
    def by($who; $login; $email): (.[$who].login // "") == $login and (.commit[$who].email // "") == $email;
    def parents: [.parents[].sha];
    def own:
      if $kind == "pin-bump" then
        by("author"; $gha; $gha_email) and by("committer"; $gha; $gha_email) and (parents | length) == 1
      else
        (by("author"; $dep; $dep_email) and by("committer"; $wf; $wf_email)
         and .commit.verification.verified == true and (parents | length) == 1)
        or (by("author"; $gha; $gha_email)
            and (by("committer"; $wf; $wf_email) or by("committer"; $gha; $gha_email))
            and (parents | length) == 2
            and (parents | sort) as $p | any($markers[]; [.head, .main] | sort == $p))
      end;
    [ .[] | select(own | not)
      | "\(.sha[:12]) (author \(.commit.author.email // "?"), committer \(.commit.committer.email // "?")\(if (.parents | length) > 1 then ", merge" else "" end))" ]
    | join("; ")'
}

# Whether the head commit (the last on stdin) is a refresh merge commit that a
# marker accounts for. MARKERS-JSON
head_is_refresh() {
  jq -e --argjson markers "$1" --arg gha "$GHA_LOGIN" '
    .[-1] | (.author.login // "") == $gha and (.parents | length) == 2
    and ([.parents[].sha] | sort) as $p | any($markers[]; [.head, .main] | sort == $p)' >/dev/null
}

# Dispatch WORKFLOW... on REF. Every one is tried; fails if any failed, with
# the failures in $note (dynamic scope: the caller's).
dispatch_on() { # REF WORKFLOW...
  local r="$1" wf rc failed=""; shift
  for wf in "$@"; do
    rc=0; run gh workflow run "$wf" --repo "$repo" --ref "$r" || rc=$?
    [ "$rc" -eq 0 ] || failed="$failed gh workflow run $wf --ref $r exited $rc;"
  done
  if [ -n "$failed" ]; then note="${note:+$note. }${failed% ;}"; return 1; fi
}

# Step 5 of the header: a red Dependabot PR behind main gets one fresh run
# against main, per main commit. Shares one_pr's locals (n, sha, ref, note,
# row) through bash's dynamic scoping. PR MARKERS-JSON
refresh() {
  local pr_n="$1" markers="$2" cmp behind rc body new_head i
  rc=0; cmp=$(gh_read "compare-$pr_n" api "repos/$repo/compare/$main_sha...$sha?per_page=1") || rc=$?
  behind=$( { [ "$rc" -eq 0 ] && jq -er '.behind_by | numbers' <<<"$cmp"; } 2>/dev/null) || behind=""
  if [ -z "$behind" ]; then
    note="$note; could not tell whether the branch is behind $base (exit $rc)"
    row unreadable "not merged"
    return 0
  fi
  if [ "$behind" -eq 0 ]; then
    row red "not merged: red on the current $base; waits for a new Dependabot version, or a human"
    return 0
  fi
  if jq -e --arg m "$main_sha" 'any(.[]; .main == $m)' <<<"$markers" >/dev/null; then
    row red "not merged: already refreshed once against $base ${main_sha:0:12} and red again; next refresh when $base moves"
    return 0
  fi

  # The marker first: if anything below fails, it still stops the next run
  # from trying again against the same main.
  body="$work/marker-$pr_n.md"
  {
    echo "The required checks failed on \`${sha:0:12}\`, and this branch is $behind commit(s) behind \`$base\`. Merging \`$base\` (\`${main_sha:0:12}\`) in once and re-running CI, in case the failure was \`$base\`'s and not this update's. This happens at most once per \`$base\` commit; if it is red again, it waits for Dependabot or a human."
    echo
    echo "Add the \`$HOLD\` label to stop this pull request from being merged automatically."
    [ -n "${RUN_URL:-}" ] && { echo; echo "Run: $RUN_URL"; }
    echo
    echo "<!-- merge-bot: refresh head=$sha main=$main_sha -->"
  } > "$body"
  rc=0; run gh pr comment "$pr_n" --repo "$repo" --body-file "$body" || rc=$?
  if [ "$rc" -ne 0 ]; then
    note="$note; could not post the refresh marker (exit $rc), so the branch was not updated"
    row error "refresh failed"
    return 1
  fi
  # expected_head_sha: GitHub refuses the update if the branch moved since it
  # was read, so a branch Dependabot just force-pushed is not merged into.
  rc=0; run gh api -X PUT "repos/$repo/pulls/$pr_n/update-branch" -f "expected_head_sha=$sha" >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    note="$note; update-branch was refused (exit $rc): a conflict, or the branch moved. Not retried until $base moves"
    row error "refresh failed"
    return 1
  fi

  # update-branch answers 202 and merges asynchronously; CI dispatched before
  # the merge commit lands would test the old head. Wait for the head to
  # move. If it does not in time, the next run finds the merge commit with no
  # checks on it and dispatches then (the heal in one_pr).
  new_head=""
  if [ -z "$dry" ]; then
    for ((i = 1; i <= poll_attempts; i++)); do
      new_head=$( { gh_read "head-$pr_n" api "repos/$repo/pulls/$pr_n" | jq -r '.head.sha'; } 2>/dev/null) || new_head=""
      [ -n "$new_head" ] && [ "$new_head" != "$sha" ] && [ "$new_head" != null ] && break
      new_head=""
      [ "$i" -lt "$poll_attempts" ] && sleep "$poll_delay"
    done
  fi
  if [ -z "$new_head" ]; then
    note="$note; updated with $base, but the merge commit had not landed after $poll_attempts look(s), so CI is left to the next run"
    row refreshed "branch updated with $base ${main_sha:0:12}"
    return 0
  fi
  sha=$new_head
  if dispatch_on "$ref" build-and-push.yml security.yml; then
    row refreshed "branch updated with $base ${main_sha:0:12}; CI dispatched on $ref"
    return 0
  fi
  row error "branch updated, but the CI dispatch failed"
  return 1
}

# ---------------------------------------------------------------------------
if [ "${1:-}" = --one-pr ]; then
  # Child mode: work, RESULTS and main_sha are inherited from the parent.
  [ $# -eq 2 ] || die "--one-pr needs a PR number"
  one_pr "$2"
  exit $?
fi

[ -n "$repo" ] || die "GITHUB_REPOSITORY is required"
if [ -z "$stub" ]; then command -v gh >/dev/null || die "gh not found"; fi
command -v jq >/dev/null || die "jq not found"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
RESULTS="$work/results.jsonl"; : > "$RESULTS"
export work RESULTS

# main's head, for "behind" and the refresh marker. Unreadable is fatal: every
# refresh decision depends on it.
rc=0; main_json=$(gh_read main api "repos/$repo/git/ref/heads/$base") || rc=$?
main_sha=$( { [ "$rc" -eq 0 ] && jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' <<<"$main_json"; } 2>/dev/null) || main_sha=""
if [ -z "$main_sha" ]; then
  log "error: could not read the head of $base (exit $rc)"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::could not read the head of $base -- nothing was merged"
  exit 1
fi
export main_sha

# Every open PR into the base branch. An unreadable list is fatal, never "no
# PRs": that would be a run that merged nothing because it did not look.
rc=0; prs=$(gh_read prs api --paginate "repos/$repo/pulls?state=open&base=$base&per_page=100") || rc=$?
if [ "$rc" -ne 0 ] || ! jq -sc '
    if length > 0 and all(.[]; type == "array") then add else error("not one or more arrays") end
    | if all(.[]; type == "object" and (.number | type) == "number") then . else error("not PR objects") end' \
    <<<"$prs" > "$work/prs.json" 2>/dev/null; then
  log "error: could not read the open pull requests (exit $rc)"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::could not read the open pull requests -- nothing was merged"
  exit 1
fi

candidates=$(jq -r --arg repo "$repo" --arg dep "$DEP_LOGIN" --arg gha "$GHA_LOGIN" '
  .[] | select((.head.repo.full_name // "") == $repo
               and ((.user.login == $dep and (.head.ref | startswith("dependabot/")))
                    or (.user.login == $gha and (.head.ref | startswith("pin-bump/")))))
  | .number' "$work/prs.json" | sort -n)
others=$(( $(jq length "$work/prs.json") - $(printf '%s' "$candidates" | grep -c . || true) ))

for n in $candidates; do
  log ""
  log "== #$n"
  before=$(wc -l < "$RESULTS")
  rc=0
  "$BASH" "$0" --one-pr "$n" || rc=$?
  if [ "$(wc -l < "$RESULTS")" -eq "$before" ]; then
    # The child died before recording anything: record it for it.
    jq -nc --argjson pr "$n" --arg rc "$rc" \
      '{pr:$pr, kind:"", branch:"", head:"", status:"error", action:"none", note:("aborted, exit " + $rc)}' >> "$RESULTS"
  fi
done

# Publish what merged: one dispatch of each, on main, however many merged.
merged=$(jq -s '[.[] | select(.status == "merged")] | length' "$RESULTS")
publish=""
if [ "$merged" -gt 0 ]; then
  for wf in build-and-push.yml security.yml; do
    rc=0; run gh workflow run "$wf" --repo "$repo" --ref "$base" || rc=$?
    if [ "$rc" -eq 0 ]; then
      publish="${publish}${publish:+, }$wf dispatched on $base"
    else
      jq -nc --arg wf "$wf" --arg base "$base" --arg rc "$rc" \
        '{pr:0, kind:"", branch:$base, head:"", status:"error", action:"publish failed",
          note:("gh workflow run " + $wf + " --ref " + $base + " exited " + $rc + "; run it by hand to publish what merged")}' >> "$RESULTS"
    fi
  done
fi

# --- summary ---------------------------------------------------------------
{
  echo "### Merge bot${dry:+ (dry run)}"
  echo
  echo "\`$base\` at \`${main_sha:0:12}\`. $(printf '%s' "$candidates" | grep -c . || true) bot pull request(s) considered; $others other open pull request(s) left alone."
  if [ -n "$publish" ]; then
    echo
    echo "Merged $merged; publishing: $publish."
  fi
  echo
  if [ ! -s "$RESULTS" ]; then
    echo "Nothing to do."
  else
    echo "| PR | branch | head | result | why |"
    echo "|---|---|---|---|---|"
    jq -r '
      def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
      "| \(if .pr == 0 then "—" else "#\(.pr)" end) | \(.branch | cell) | \(if .head == "" then "—" else "`\(.head)`" end) | \(if .status == "error" then "**error**" else .status end): \(.action | cell) | \(.note | cell) |"' "$RESULTS"
  fi
} > "$work/summary.md"
[ -z "${MERGE_BOT_RESULTS:-}" ] || cp "$RESULTS" "$MERGE_BOT_RESULTS"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$work/summary.md" >> "$GITHUB_STEP_SUMMARY"
cat "$work/summary.md"

# Annotations: red and unreadable PRs are warnings (a state to look at, not a
# failure of this job); anything this run failed to do is an error.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  jq -r 'select(.status == "red" or .status == "unreadable") | "::warning::#\(.pr) \(.branch): \(.status): \(.note)"' "$RESULTS"
  jq -r 'select(.status == "error") | "::error::\(if .pr == 0 then "" else "#\(.pr) " end)\(.branch): \(.action): \(.note)"' "$RESULTS"
fi

errors=$(jq -s '[.[] | select(.status == "error")] | length' "$RESULTS")
if [ "$errors" -gt 0 ]; then
  log "error: $errors action(s) failed; see the summary"
  exit 1
fi
exit 0
