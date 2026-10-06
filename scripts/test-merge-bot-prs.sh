#!/usr/bin/env bash
# Offline tests for scripts/merge-bot-prs.sh. No network and no git: every
# read-only GitHub query is answered from a stub directory (MERGE_BOT_GH_STUB)
# in the shape the REST API returns -- checked against the live API for the
# pull, commit, check-run and compare objects -- and every write goes to a
# fake gh on PATH that logs it, and refuses the calls a case says should fail.
#
#   ./scripts/test-merge-bot-prs.sh    # run by scripts/lint.sh, so CI runs it too
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bot="$here/merge-bot-prs.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
# The fake: log every call, keep any --body-file, refuse what FAKE_GH_FAIL
# matches (saying FAKE_GH_ERR, when set, as GitHub would). Reads never get
# here: they come from the stub directory.
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
prev=""
for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$FAKE_GH_LOG.body"; prev="$a"; done
if [ -n "${FAKE_GH_FAIL:-}" ] && printf '%s\n' "$*" | grep -qE "$FAKE_GH_FAIL"; then
  echo "${FAKE_GH_ERR:-gh (fake): refused: $*}" >&2; exit 1
fi
exit 0
EOF
chmod +x "$work/bin/gh"

sha() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }
MAIN=$(sha main); OLDMAIN=$(sha old-main)
DEP_EMAIL='49699333+dependabot[bot]@users.noreply.github.com'
GHA_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
CHECKS=("CI result" "Repository secret scan" "CodeQL (workflows)" "Dependency review")

# --- fixture writers ------------------------------------------------------------
# scenario NAME -- an empty stub directory with main's head, and an empty log.
scenario() {
  d="$work/$1"; rm -rf "$d"; mkdir -p "$d/stub"
  stub="$d/stub"; log="$d/gh.log"; : > "$log"
  jq -n --arg s "$MAIN" '{ref: "refs/heads/main", object: {sha: $s, type: "commit"}}' > "$stub/main.json"
  echo '[]' > "$stub/prs.json"
}
# commit SHA PARENT[,PARENT2] AUTHOR_LOGIN AUTHOR_EMAIL COMMITTER_LOGIN COMMITTER_EMAIL VERIFIED
commit() {
  jq -nc --arg sha "$1" --arg parents "$2" --arg al "$3" --arg ae "$4" --arg cl "$5" --arg ce "$6" --argjson v "$7" '
    {sha: $sha,
     commit: {author: {name: $al, email: $ae}, committer: {name: $cl, email: $ce},
              message: "m", verification: {verified: $v, reason: (if $v then "valid" else "unsigned" end)}},
     author: (if $al == "" then null else {login: $al, type: "Bot"} end),
     committer: (if $cl == "" then null else {login: $cl, type: "Bot"} end),
     parents: ($parents | split(",") | map({sha: .}))}'
}
dep_commit() { commit "$1" "${2:-$OLDMAIN}" 'dependabot[bot]' "$DEP_EMAIL" web-flow noreply@github.com true; }
gha_commit() { commit "$1" "${2:-$OLDMAIN}" 'github-actions[bot]' "$GHA_EMAIL" 'github-actions[bot]' "$GHA_EMAIL" false; }
# A merge of main into the branch, as update-branch makes it.
refresh_commit() { commit "$1" "$2,$3" 'github-actions[bot]' "$GHA_EMAIL" web-flow noreply@github.com true; }

# pr N KIND HEAD [LABEL...] -- a candidate PR in the list, with its detail
# (open, mergeable) and, unless a case replaces them, one bot commit and all
# four checks green.
pr() {
  local n="$1" kind="$2" head="$3"; shift 3
  local login ref
  if [ "$kind" = dependabot ]; then login='dependabot[bot]'; ref="dependabot/github_actions/x-$n"
  else login='github-actions[bot]'; ref="pin-bump/tool-$n"; fi
  local labels; labels=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != "") | {name: .})')
  jq --argjson n "$n" --arg l "$login" --arg r "$ref" --arg s "$head" --argjson labels "$labels" \
    '. + [{number: $n, user: {login: $l, type: "Bot"}, draft: false, labels: $labels,
           head: {ref: $r, sha: $s, repo: {full_name: "o/r"}}, base: {ref: "main"}}]' \
    "$stub/prs.json" > "$stub/prs.tmp" && mv "$stub/prs.tmp" "$stub/prs.json"
  detail "$n" "$head" 1 true "$labels"
  if [ "$kind" = dependabot ]; then dep_commit "$head" | jq -s . > "$stub/commits-$n.json"
  else gha_commit "$head" | jq -s . > "$stub/commits-$n.json"; fi
  checks "$n" success success success success
  echo '[]' > "$stub/comments-$n.json"
  files "$n" "ci-node22/Dockerfile.ci"
}
# files N PATH... -- the PR's changed files, as `GET pulls/N/files` lists them.
files() {
  local n="$1"; shift
  printf '%s\n' "$@" | jq -R '{filename: ., status: "modified"}' | jq -s . > "$stub/files-$n.json"
}
# detail N HEAD COMMITS MERGEABLE [LABELS-JSON] [FILE] -- the PR as
# `GET pulls/N` returns it; FILE defaults to pr-N.json (pr-N.2.json is the
# second read: the re-check right before a write).
detail() {
  jq -n --argjson n "$1" --arg s "$2" --argjson c "$3" --argjson m "$4" --argjson l "${5:-[]}" \
    '{number: $n, state: "open", draft: false, head: {sha: $s}, commits: $c, mergeable: $m, labels: $l}' \
    > "$stub/${6:-pr-$1.json}"
}
# checks N S1 S2 S3 S4 -- the latest run of each required check, in
# CHECKS order: success, failure, cancelled, in_progress, skipped, or none.
checks() {
  local n="$1"; shift
  local i=0 runs="" st
  for st in "$@"; do
    if [ "$st" != none ]; then
      runs="$runs$(jq -nc --argjson id "$((1000 + i))" --arg name "${CHECKS[$i]}" --arg st "$st" '
        {id: $id, name: $name, app: {slug: "github-actions"},
         status: (if $st == "in_progress" then "in_progress" else "completed" end),
         conclusion: (if $st == "in_progress" then null else $st end)}')"
    fi
    i=$((i + 1))
  done
  printf '%s' "$runs" | jq -s '{total_count: length, check_runs: .}' > "$stub/checks-$n.json"
}
# add_run N ID NAME CONCLUSION [APP] -- one more check run.
add_run() {
  jq --argjson id "$2" --arg name "$3" --arg c "$4" --arg app "${5:-github-actions}" \
    '.check_runs += [{id: $id, name: $name, app: {slug: $app}, status: "completed", conclusion: $c}]
     | .total_count = (.check_runs | length)' "$stub/checks-$1.json" > "$stub/c.tmp" && mv "$stub/c.tmp" "$stub/checks-$1.json"
}
# marker N HEAD MAIN [LOGIN TYPE] -- a refresh marker comment.
marker() {
  jq --arg h "$2" --arg m "$3" --arg l "${4:-github-actions[bot]}" --arg t "${5:-Bot}" \
    '. + [{user: {login: $l, type: $t}, body: ("text\n\n<!-- merge-bot: refresh head=" + $h + " main=" + $m + " -->")}]' \
    "$stub/comments-$1.json" > "$stub/m.tmp" && mv "$stub/m.tmp" "$stub/comments-$1.json"
}

# run_bot [ENV=VALUE...] -- sets rc, out, res.
run_bot() {
  out="$d/out"; res="$d/results.jsonl"; rc=0; rm -f "$res"
  env PATH="$work/bin:$PATH" GITHUB_REPOSITORY=o/r MERGE_BOT_GH_STUB="$stub" MERGE_BOT_RESULTS="$res" \
    FAKE_GH_LOG="$log" MERGE_BOT_POLL_ATTEMPTS=2 MERGE_BOT_POLL_DELAY=0 GITHUB_ACTIONS=true "$@" "$bot" > "$out" 2>&1 || rc=$?
}
field() { jq -r --argjson n "$1" --arg f "$2" 'select(.pr == $n) | .[$f]' "$res"; }
expect() { # PR FIELD VALUE
  local got; got=$(field "$1" "$2")
  if [ "$got" = "$3" ]; then ok "#$1 $2 = $3"; else bad "#$1 $2: expected $3, got $got"; fi
}
logged()     { grep -qxF -- "$1" "$log"; }
not_logged() { ! grep -qE -- "$1" "$log"; }
no_writes()  { [ ! -s "$log" ]; }

H1=$(sha h1); H2=$(sha h2); H3=$(sha h3); MERGE=$(sha merge)

# --- cases -----------------------------------------------------------------------
echo "case 1: green PRs of both kinds merge, then main is published once"
scenario one
pr 11 dependabot "$H1"
pr 12 pin-bump "$H2" needs-review
run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 11 status merged
expect 12 status merged
check "Dependabot PR merged, leased to its head" logged "pr merge 11 --repo o/r --squash --match-head-commit $H1"
check "pin-bump PR merged, needs-review is information only" logged "pr merge 12 --repo o/r --squash --match-head-commit $H2"
check "Build and Push dispatched on main" logged "workflow run build-and-push.yml --repo o/r --ref main"
check "Security dispatched on main" logged "workflow run security.yml --repo o/r --ref main"
check "  once each, for two merges" [ "$(grep -c '^workflow run' "$log")" -eq 2 ]
check "summary has a row per PR" bash -c "grep -q '^| #11 | dependabot/github_actions/x-11 |' '$out' && grep -q '^| #12 | pin-bump/tool-12 |' '$out'"

echo "case 2: who and what is a candidate"
scenario two
pr 21 dependabot "$H1"
# A fork's branch named like Dependabot's, and a human's PR: neither is read.
jq --arg s "$H2" '. + [{number: 22, user: {login: "dependabot[bot]"}, labels: [], head: {ref: "dependabot/npm/x", sha: $s, repo: {full_name: "fork/r"}}},
                        {number: 23, user: {login: "someone"}, labels: [], head: {ref: "dependabot/npm/y", sha: $s, repo: {full_name: "o/r"}}},
                        {number: 24, user: {login: "github-actions[bot]"}, labels: [], head: {ref: "feature/x", sha: $s, repo: {full_name: "o/r"}}}]' \
  "$stub/prs.json" > "$stub/p.tmp" && mv "$stub/p.tmp" "$stub/prs.json"
run_bot
check "exit 0" [ "$rc" -eq 0 ]
check "only the real bot PR has a row" [ "$(jq -s 'map(.pr) | join(",")' "$res")" = '"21"' ]
check "the summary counts the rest" grep -q '1 bot pull request(s) considered; 3 other open pull request(s) left alone' "$out"
check "none of the others merged" not_logged '^pr merge 2[234] '

echo "case 3: the hold label"
scenario three
pr 31 dependabot "$H1" hold
run_bot
expect 31 status held
check "no write at all, not even a publish" no_writes

echo "case 4: commits that are not the bot's own -> left alone"
scenario four
pr 41 dependabot "$H2"
{ dep_commit "$H1"; commit "$H2" "$H1" maintainer m@example.com maintainer m@example.com false; } | jq -s . > "$stub/commits-41.json"
detail 41 "$H2" 2 true
pr 42 pin-bump "$H3"
commit "$H3" "$OLDMAIN" 'github-actions[bot]' "$GHA_EMAIL" maintainer m@example.com false | jq -s . > "$stub/commits-42.json"
# Dependabot's commit, but committed by Dependabot rather than web-flow, and
# one by web-flow but not signed: both outside what Dependabot's commits look
# like, so both fail closed.
pr 43 dependabot "$H1"
commit "$H1" "$OLDMAIN" 'dependabot[bot]' "$DEP_EMAIL" 'dependabot[bot]' "$DEP_EMAIL" true | jq -s . > "$stub/commits-43.json"
pr 44 dependabot "$H1"
commit "$H1" "$OLDMAIN" 'dependabot[bot]' "$DEP_EMAIL" web-flow noreply@github.com false | jq -s . > "$stub/commits-44.json"
# The bot's email on a commit GitHub does not attribute to the bot.
pr 45 dependabot "$H1"
commit "$H1" "$OLDMAIN" '' "$DEP_EMAIL" web-flow noreply@github.com true | jq -s . > "$stub/commits-45.json"
run_bot
check "exit 0" [ "$rc" -eq 0 ]
for n in 41 42 43 44 45; do expect "$n" status skipped; done
check "the note names the foreign commit" bash -c "jq -r 'select(.pr == 41) | .note' '$res' | grep -q 'author m@example.com'"
check "the note names a foreign committer on a pin-bump branch" bash -c "jq -r 'select(.pr == 42) | .note' '$res' | grep -q 'committer m@example.com'"
check "nothing merged, nothing published" no_writes

echo "case 5: checks that are not all green -> not merged"
scenario five
pr 51 pin-bump "$H1"; checks 51 success success in_progress success
pr 52 pin-bump "$H1"; checks 52 success none success success
pr 53 pin-bump "$H1"; checks 53 skipped success success success
pr 54 pin-bump "$H1"; checks 54 success success success failure
pr 55 pin-bump "$H1"; checks 55 cancelled success success success
# A "CI result" from another app does not stand in for GitHub Actions'.
pr 56 pin-bump "$H1"; checks 56 none success success success; add_run 56 2000 "CI result" success some-other-app
# The latest run of a name wins, both ways.
pr 57 pin-bump "$H1"; checks 57 failure success success success; add_run 57 3000 "CI result" success
pr 58 pin-bump "$H1"; checks 58 success success success success; add_run 58 3000 "CI result" failure
run_bot
check "exit 0: red is a state, not a failure of this job" [ "$rc" -eq 0 ]
expect 51 status waiting
check "  the note says which and how" bash -c "jq -r 'select(.pr == 51) | .note' '$res' | grep -q 'CodeQL (workflows) (in_progress)'"
expect 52 status waiting
expect 53 status waiting
expect 54 status red
expect 55 status red
expect 56 status waiting
expect 57 status merged
expect 58 status red
check "only #57 merged" [ "$(grep '^pr merge' "$log")" = "pr merge 57 --repo o/r --squash --match-head-commit $H1" ]
check "a red PR is a warning annotation" grep -q '^::warning::#54 pin-bump/tool-54: red: failed on' "$out"
check "a waiting PR is not" bash -c "! grep -q '^::warning::#51' '$out'"
check "a red pin-bump PR is never update-branched" not_logged 'update-branch'

echo "case 6: what cannot be read is never merged"
scenario six
pr 61 dependabot "$H1"; echo '{"message":"Server Error"}' > "$stub/checks-61.json"; echo 1 > "$stub/checks-61.exit"
pr 62 dependabot "$H1"; jq '.total_count = 150' "$stub/checks-62.json" > "$stub/c.tmp" && mv "$stub/c.tmp" "$stub/checks-62.json"
pr 63 dependabot "$H1"; detail 63 "$H1" 2 true          # the PR says 2 commits, the list has 1
pr 64 dependabot "$H1"; rm "$stub/commits-64.json"      # the commit list cannot be read
pr 65 dependabot "$H1"; echo 1 > "$stub/comments-65.exit"
pr 66 dependabot "$H1"; rm "$stub/pr-66.json"           # the PR detail cannot be read
pr 67 dependabot "$H1"; detail 67 "$H2" 1 true          # the list is older than the PR: the head moved
run_bot
check "exit 0" [ "$rc" -eq 0 ]
for n in 61 62 63 64 65 66 67; do expect "$n" status unreadable; done
check "nothing merged" no_writes
check "unreadable is a warning annotation" grep -q '^::warning::#61 .*: unreadable: could not read the check runs for: CI result' "$out"

echo "case 7: mergeability"
scenario seven
pr 71 pin-bump "$H1"; detail 71 "$H1" 1 false
pr 72 pin-bump "$H1"; detail 72 "$H1" 1 null
run_bot
expect 71 status waiting
check "  a conflict says so" bash -c "jq -r 'select(.pr == 71) | .action' '$res' | grep -q 'conflicts with main'"
expect 72 status waiting
check "neither merged" no_writes

echo "case 8: a refused merge errors that PR, after every PR was processed"
scenario eight
pr 81 dependabot "$H1"
pr 82 dependabot "$H2"
FAKE_GH_FAIL='^pr merge 81 ' run_bot
check "exit 1" [ "$rc" -eq 1 ]
expect 81 status error
expect 82 status merged
check "the merge that did happen is still published" logged "workflow run build-and-push.yml --repo o/r --ref main"
check "an error annotation" grep -q '^::error::#81 .*merge failed' "$out"
scenario eight-b
pr 83 dependabot "$H1"
FAKE_GH_FAIL='^pr merge 83 ' run_bot
check "nothing merged -> nothing published" not_logged '^workflow run'

echo "case 9: a red Dependabot PR behind main is refreshed once"
scenario nine
pr 91 dependabot "$H1"; checks 91 failure success success success
echo '{"status":"diverged","ahead_by":1,"behind_by":3}' > "$stub/compare-91.json"
jq -n --arg s "$MERGE" '{head: {sha: $s}}' > "$stub/head-91.json"
run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 91 status refreshed
check "the marker comment was posted first" bash -c "head -1 '$log' | grep -q '^pr comment 91 --repo o/r --body-file '"
check "  recording head and main" grep -qxF "<!-- merge-bot: refresh head=$H1 main=$MAIN -->" "$log.body"
check "update-branch, leased to the head that was read" logged "api -X PUT repos/o/r/pulls/91/update-branch -f expected_head_sha=$H1"
check "CI dispatched on the branch" logged "workflow run build-and-push.yml --repo o/r --ref dependabot/github_actions/x-91"
check "  both workflows" logged "workflow run security.yml --repo o/r --ref dependabot/github_actions/x-91"
check "nothing merged, main not dispatched" not_logged '^(pr merge|workflow run .* --ref main$)'
# Already refreshed against this main: not again.
scenario nine-b
pr 92 dependabot "$H1"; checks 92 failure success success success
echo '{"behind_by":3}' > "$stub/compare-92.json"
marker 92 "$(sha older-head)" "$MAIN"
run_bot
expect 92 status red
check "  no second refresh against the same main" no_writes
# A marker against an older main does not stop a refresh against the new one.
scenario nine-c
pr 93 dependabot "$H1"; checks 93 failure success success success
echo '{"behind_by":1}' > "$stub/compare-93.json"
marker 93 "$(sha older-head)" "$OLDMAIN"
jq -n --arg s "$MERGE" '{head: {sha: $s}}' > "$stub/head-93.json"
run_bot
expect 93 status refreshed
# Red on a branch that is not behind: the failure is the update's own.
scenario nine-d
pr 94 dependabot "$H1"; checks 94 success success success failure
echo '{"behind_by":0}' > "$stub/compare-94.json"
run_bot
expect 94 status red
check "  no refresh" no_writes
# update-branch accepted, but the merge commit does not land in time: CI is
# left to the next run, which the heal below covers.
scenario nine-e
pr 95 dependabot "$H1"; checks 95 failure success success success
echo '{"behind_by":2}' > "$stub/compare-95.json"
jq -n --arg s "$H1" '{head: {sha: $s}}' > "$stub/head-95.json"
run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 95 status refreshed
check "  updated" logged "api -X PUT repos/o/r/pulls/95/update-branch -f expected_head_sha=$H1"
check "  but no dispatch on the old head" not_logged '^workflow run'
# update-branch refused: an error, and the marker stops a retry on this main.
scenario nine-f
pr 96 dependabot "$H1"; checks 96 failure success success success
echo '{"behind_by":2}' > "$stub/compare-96.json"
FAKE_GH_FAIL='update-branch' run_bot
check "exit 1" [ "$rc" -eq 1 ]
expect 96 status error
check "  the marker was posted before the attempt" grep -q '^pr comment 96 ' "$log"
# The comment refused: no update without a marker.
scenario nine-g
pr 97 dependabot "$H1"; checks 97 failure success success success
echo '{"behind_by":2}' > "$stub/compare-97.json"
FAKE_GH_FAIL='^pr comment' run_bot
expect 97 status error
check "  no update-branch without its marker" not_logged 'update-branch'
# Whether it is behind cannot be read: unreadable, no refresh.
scenario nine-h
pr 98 dependabot "$H1"; checks 98 failure success success success
run_bot
expect 98 status unreadable
check "  no refresh on a guess" no_writes

echo "case 10: a refreshed branch -- the merge commit is accepted only with its marker"
scenario ten
pr 101 dependabot "$MERGE"
{ dep_commit "$H1"; refresh_commit "$MERGE" "$H1" "$MAIN"; } | jq -s . > "$stub/commits-101.json"
detail 101 "$MERGE" 2 true
marker 101 "$H1" "$MAIN"
run_bot
expect 101 status merged
check "merged at the merge commit" logged "pr merge 101 --repo o/r --squash --match-head-commit $MERGE"
# The same merge commit, no marker.
scenario ten-b
pr 102 dependabot "$MERGE"
{ dep_commit "$H1"; refresh_commit "$MERGE" "$H1" "$MAIN"; } | jq -s . > "$stub/commits-102.json"
detail 102 "$MERGE" 2 true
run_bot
expect 102 status skipped
check "  no marker, no merge" no_writes
# A marker written by someone else is no marker.
scenario ten-c
pr 103 dependabot "$MERGE"
{ dep_commit "$H1"; refresh_commit "$MERGE" "$H1" "$MAIN"; } | jq -s . > "$stub/commits-103.json"
detail 103 "$MERGE" 2 true
marker 103 "$H1" "$MAIN" someone User
run_bot
expect 103 status skipped
# A marker whose parents do not match this merge commit.
scenario ten-d
pr 104 dependabot "$MERGE"
{ dep_commit "$H1"; refresh_commit "$MERGE" "$H1" "$MAIN"; } | jq -s . > "$stub/commits-104.json"
detail 104 "$MERGE" 2 true
marker 104 "$H1" "$OLDMAIN"
run_bot
expect 104 status skipped
# A merge commit by a person ("Update branch" clicked), even with a marker.
scenario ten-e
pr 105 dependabot "$MERGE"
{ dep_commit "$H1"; commit "$MERGE" "$H1,$MAIN" maintainer m@example.com web-flow noreply@github.com true; } | jq -s . > "$stub/commits-105.json"
detail 105 "$MERGE" 2 true
marker 105 "$H1" "$MAIN"
run_bot
expect 105 status skipped
# The refresh merge commit on a pin-bump branch is not accepted at all.
scenario ten-f
pr 106 pin-bump "$MERGE"
{ gha_commit "$H1"; refresh_commit "$MERGE" "$H1" "$MAIN"; } | jq -s . > "$stub/commits-106.json"
detail 106 "$MERGE" 2 true
run_bot
expect 106 status skipped

echo "case 11: a refresh merge commit whose CI never started -> dispatched"
scenario eleven
pr 111 dependabot "$MERGE"
{ dep_commit "$H1"; refresh_commit "$MERGE" "$H1" "$MAIN"; } | jq -s . > "$stub/commits-111.json"
detail 111 "$MERGE" 2 true
marker 111 "$H1" "$MAIN"
checks 111 none success success success
run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 111 status refreshed
check "only the workflow whose check is missing" [ "$(grep '^workflow run' "$log")" = "workflow run build-and-push.yml --repo o/r --ref dependabot/github_actions/x-111" ]
# An ordinary Dependabot PR whose checks are missing is just waiting.
scenario eleven-b
pr 112 dependabot "$H1"; checks 112 none none none none
run_bot
expect 112 status waiting
check "  nothing dispatched for it" no_writes

echo "case 12: what the run cannot do without"
scenario twelve
echo 1 > "$stub/main.exit"
run_bot
check "main unreadable: exit 1" [ "$rc" -eq 1 ]
check "  nothing written" no_writes
scenario twelve-b
pr 121 dependabot "$H1"
echo '{"message":"Bad credentials"}' > "$stub/prs.json"
run_bot
check "PR list not a list: exit 1, never 'no PRs'" [ "$rc" -eq 1 ]
check "  an error annotation" grep -q '^::error::could not read the open pull requests' "$out"
scenario twelve-c
pr 122 dependabot "$H1"
FAKE_GH_FAIL='^workflow run security' run_bot
check "a failed publish dispatch: exit 1" [ "$rc" -eq 1 ]
expect 122 status merged
check "  and says to run it by hand" grep -q 'run it by hand to publish what merged' "$res"

echo "case 13: dry run"
scenario thirteen
pr 131 dependabot "$H1"
pr 132 dependabot "$H2"; checks 132 failure success success success
echo '{"behind_by":1}' > "$stub/compare-132.json"
run_bot DRY_RUN=1
check "exit 0" [ "$rc" -eq 0 ]
check "nothing written" no_writes
check "the merge is printed" grep -q "DRY-RUN would run: gh pr merge 131 --repo o/r --squash --match-head-commit $H1" "$out"
check "the refresh is printed" grep -q 'DRY-RUN would run: gh api -X PUT repos/o/r/pulls/132/update-branch' "$out"
check "the publish is printed" grep -q 'DRY-RUN would run: gh workflow run build-and-push.yml --repo o/r --ref main' "$out"

echo "case 14: a merge GitHub refuses for want of the workflows permission -> skipped, a warning"
scenario fourteen
pr 141 dependabot "$H1"
pr 142 dependabot "$H2"
FAKE_GH_FAIL='^pr merge 141 ' \
FAKE_GH_ERR="GraphQL: refusing to allow a GitHub App to create or update workflow \`.github/workflows/security.yml\` without \`workflows\` permission (mergePullRequest)" run_bot
check "exit 0: a standing limit must not make every run red" [ "$rc" -eq 0 ]
expect 141 status skipped
check "  the note says what to do" bash -c "jq -r 'select(.pr == 141) | .note' '$res' | grep -q 'GITHUB_TOKEN cannot merge workflow-file changes; merge by hand or provide a token with workflows:write'"
check "  a warning annotation, not an error" bash -c "grep -q '^::warning::#141 .*skipped: GITHUB_TOKEN cannot merge' '$out' && ! grep -q '^::error::' '$out'"
expect 142 status merged
# Other wording, same meaning: matched on "workflow" and "permission".
scenario fourteen-b
pr 143 pin-bump "$H1"
FAKE_GH_FAIL='^pr merge 143 ' FAKE_GH_ERR='HTTP 403: Resource not accessible: the Workflows permission is required to change .github/workflows/build-image.yml' run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 143 status skipped
# Any other refusal is still an error (case 8 has the generic one).
scenario fourteen-c
pr 144 dependabot "$H1"
FAKE_GH_FAIL='^pr merge 144 ' FAKE_GH_ERR='GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)' run_bot
check "a different refusal: exit 1" [ "$rc" -eq 1 ]
expect 144 status error

echo "case 15: refreshes are capped at two per PR in all"
scenario fifteen
pr 151 dependabot "$H1"; checks 151 failure success success success
echo '{"behind_by":1}' > "$stub/compare-151.json"
marker 151 "$(sha older-head-1)" "$(sha older-main-1)"
marker 151 "$(sha older-head-2)" "$OLDMAIN"
run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 151 status stale
check "  no third refresh, against a main it has never seen" no_writes
check "  a warning annotation" grep -q '^::warning::#151 .*stale: ' "$out"
check "  the note says why, and what supersedes it" bash -c "jq -r 'select(.pr == 151) | .note' '$res' | grep -q 'next version of this update opens a new PR that supersedes this one'"
# Markers by anyone else do not count towards the cap either.
scenario fifteen-b
pr 152 dependabot "$H1"; checks 152 failure success success success
echo '{"behind_by":1}' > "$stub/compare-152.json"
marker 152 "$(sha older-head-1)" "$(sha older-main-1)" someone User
marker 152 "$(sha older-head-2)" "$OLDMAIN" someone User
jq -n --arg s "$MERGE" '{head: {sha: $s}}' > "$stub/head-152.json"
run_bot
expect 152 status refreshed

echo "case 16: no refresh of a branch that does not merge cleanly"
scenario sixteen
pr 161 dependabot "$H1"; checks 161 failure success success success; detail 161 "$H1" 1 false
echo '{"behind_by":4}' > "$stub/compare-161.json"
pr 162 dependabot "$H2"; checks 162 failure success success success; detail 162 "$H2" 1 null
echo '{"behind_by":4}' > "$stub/compare-162.json"
run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 161 status waiting
check "  the conflict is named" bash -c "jq -r 'select(.pr == 161) | .action' '$res' | grep -q 'conflicts with main'"
expect 162 status waiting
check "  neither refreshed" no_writes

echo "case 17: hold and the head are read fresh, and again right before writing"
scenario seventeen
# The list (minutes old) says hold, the PR now does not: it merges.
pr 171 dependabot "$H1" hold; detail 171 "$H1" 1 true
# The list does not say hold, the PR now does: held.
pr 172 dependabot "$H2"; detail 172 "$H2" 1 true '[{"name":"hold"}]'
# hold added while it was being checked: the re-check catches it.
pr 173 pin-bump "$H3"; detail 173 "$H3" 1 true '[{"name":"hold"}]' pr-173.2.json
# A push while it was being checked: the re-check catches it.
pr 174 pin-bump "$H1"; detail 174 "$H2" 1 true '[]' pr-174.2.json
run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 171 status merged
expect 172 status held
expect 173 status held
expect 174 status waiting
check "  only #171 merged" [ "$(grep '^pr merge' "$log")" = "pr merge 171 --repo o/r --squash --match-head-commit $H1" ]
# The same re-check guards a refresh.
scenario seventeen-b
pr 175 dependabot "$H1"; checks 175 failure success success success
echo '{"behind_by":2}' > "$stub/compare-175.json"
detail 175 "$H1" 1 true '[{"name":"hold"}]' pr-175.2.json
run_bot
expect 175 status held
check "  no marker, no update-branch" no_writes

echo "case 18: CI is never dispatched on a Dependabot branch that changes .github/"
scenario eighteen
# An action bump, red and behind main: not refreshed, not dispatched.
pr 181 dependabot "$H1"; checks 181 failure success success success
echo '{"behind_by":3}' > "$stub/compare-181.json"
files 181 .github/workflows/build-image.yml .github/workflows/security.yml
# A file moved out of .github/ counts too.
pr 182 dependabot "$H2"; checks 182 failure success success success
echo '{"behind_by":3}' > "$stub/compare-182.json"
jq -n '[{filename: "docs/x.yml", previous_filename: ".github/workflows/x.yml", status: "renamed"}]' > "$stub/files-182.json"
run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 181 status stale
expect 182 status stale
check "  no marker, no update-branch, no dispatch" no_writes
check "  the note says why" bash -c "jq -r 'select(.pr == 181) | .note' '$res' | grep -q 'touches .github/: not re-run with write tokens; Dependabot rebases it on conflict or supersedes it with its next version'"
check "  a warning annotation" grep -q '^::warning::#181 .*stale: ' "$out"
# The same PR, green: it still merges -- on its own pull_request CI.
scenario eighteen-b
pr 183 dependabot "$H1"; files 183 .github/workflows/build-image.yml
run_bot
expect 183 status merged
# Red and behind, changing only an image directory: refreshed.
scenario eighteen-c
pr 184 dependabot "$H1"; checks 184 failure success success success
echo '{"behind_by":3}' > "$stub/compare-184.json"
files 184 ci-python313/Dockerfile.ci
jq -n --arg s "$MERGE" '{head: {sha: $s}}' > "$stub/head-184.json"
run_bot
expect 184 status refreshed
check "  update-branch and dispatch on the branch" bash -c "grep -q 'update-branch' '$log' && grep -q '^workflow run build-and-push.yml --repo o/r --ref dependabot/github_actions/x-184$' '$log'"
# The file list cannot be read: no refresh on a guess.
scenario eighteen-d
pr 185 dependabot "$H1"; checks 185 failure success success success
echo '{"behind_by":3}' > "$stub/compare-185.json"
echo '{"message":"Server Error"}' > "$stub/files-185.json"; echo 1 > "$stub/files-185.exit"
# Or is shorter than the PR says it is.
pr 186 dependabot "$H2"; checks 186 failure success success success
echo '{"behind_by":3}' > "$stub/compare-186.json"
jq '.changed_files = 2' "$stub/pr-186.json" > "$stub/p.tmp" && mv "$stub/p.tmp" "$stub/pr-186.json"
run_bot
check "exit 0" [ "$rc" -eq 0 ]
expect 185 status unreadable
expect 186 status unreadable
check "  neither refreshed" no_writes
# The heal path obeys the same rule: a refresh merge commit with no checks,
# on a branch that (now) changes .github/, is not dispatched on.
scenario eighteen-e
pr 187 dependabot "$MERGE"
{ dep_commit "$H1"; refresh_commit "$MERGE" "$H1" "$MAIN"; } | jq -s . > "$stub/commits-187.json"
detail 187 "$MERGE" 2 true
marker 187 "$H1" "$MAIN"
checks 187 none success success success
files 187 .github/workflows/security.yml
run_bot
expect 187 status stale
check "  nothing dispatched" no_writes

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
