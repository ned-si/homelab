#!/bin/bash
# scripts/pr-merge.sh against the fake gh of lib.sh and a local git origin:
# the auto-merge flow, refusals, the freeze and its exemption, the revert
# wait, the rebase, and gh's stderr hints (#1793).
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
install_fake_gh "$tmp/libbin"
export PR_MERGE_REPO=ned-si/homelab PR_MERGE_POLL=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export ORIGIN="$tmp/origin.git" LIBGH="$tmp/libbin/gh"
R=repos/ned-si/homelab

# A local "origin" with main at A and a PR branch at B (child of A).
git init -q --bare "$ORIGIN"
git init -q "$tmp/work"
git -C "$tmp/work" config commit.gpgsign false
echo a > "$tmp/work/a"
git -C "$tmp/work" add a
git -C "$tmp/work" commit -q -m "chore: a"
git -C "$tmp/work" branch -M main
git -C "$tmp/work" remote add origin "$ORIGIN"
git -C "$tmp/work" push -q origin main
git -C "$tmp/work" checkout -q -b feature
echo b > "$tmp/work/b"
git -C "$tmp/work" add b
git -C "$tmp/work" commit -q -m "ci: add b"
git -C "$tmp/work" push -q origin feature
HEAD_SHA=$(git -C "$tmp/work" rev-parse HEAD)
MERGE_SHA=f00df00df00df00df00df00df00df00df00df00d
OTHER_SHA=0123456789abcdef0123456789abcdef01234567
export HEAD_SHA MERGE_SHA

# gh wrapper: `compare` comes from the origin unless the test set the route;
# with $FAKE_GH_DIR/live, `pulls/7` follows the origin's feature head (merged
# on the second read of a rebased head) and `ci` succeeds on any head.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
d=$FAKE_GH_DIR
key=$(printf '%s' "${2:-}" | tr '/?=&' '____')
answer() { # <json>: as gh api --jq would
  echo "$*" >> "$d/calls.log"
  if [ -f "$d/stderr-hint" ]; then cat "$d/stderr-hint" >&2; fi
  printf '%s\n' "$1" | jq -r "$JQ"
  exit 0
}
if [ "$1" = api ] && [ "${3:-}" = --jq ]; then
  JQ=$4
  case "$2" in
    repos/ned-si/homelab/compare/main...*)
      if [ ! -e "$d/api/$key.status" ] && [ ! -d "$d/api/$key.seq" ]; then
        sha=${2##*...}
        answer "{\"behind_by\":$(git --git-dir="$ORIGIN" rev-list --count "$sha..main"),\"base_commit\":{\"sha\":\"$(git --git-dir="$ORIGIN" rev-parse main)\"}}"
      fi ;;
    repos/ned-si/homelab/pulls/7)
      if [ -f "$d/live" ]; then
        h=$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature)
        n=$(( $(cat "$d/reads-$h" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$d/reads-$h"
        if [ "$h" != "$HEAD_SHA" ] && [ "$n" -ge 2 ]; then
          answer "$(prj state=closed merged=true head="$h" am="$(cat "$d/live")")"
        fi
        answer "$(prj head="$h" am="$(cat "$d/live")")"
      fi ;;
    repos/ned-si/homelab/actions/workflows/ci.yaml/runs*)
      [ ! -f "$d/live" ] || answer '{"workflow_runs":[{"status":"completed","conclusion":"success"}]}' ;;
    repos/ned-si/homelab/commits/*/check-runs*)
      [ ! -f "$d/live" ] || answer '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-11-27T10:00:00Z"}]}' ;;
  esac
fi
exec "$LIBGH" "$@"
FAKE
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# prj [state=open] [am=off] [head=$HEAD_SHA] [draft=false] [base=main] [merged=false] [user=ned-si]
prj() {
  local state=open am=off head=$HEAD_SHA draft=false base=main merged=false user=ned-si kv a
  for kv in "$@"; do
    case "$kv" in
      state=*) state=${kv#*=} ;; am=*) am=${kv#*=} ;; head=*) head=${kv#*=} ;;
      draft=*) draft=${kv#*=} ;; base=*) base=${kv#*=} ;; merged=*) merged=${kv#*=} ;;
      user=*) user=${kv#*=} ;;
    esac
  done
  a=null
  [ "$am" = off ] || a='{"merge_method":"squash"}'
  printf '{"state":"%s","merged":%s,"draft":%s,"base":{"ref":"%s"},"head":{"ref":"feature","sha":"%s","repo":{"full_name":"ned-si/homelab"}},"user":{"login":"%s"},"auto_merge":%s,"merge_commit_sha":"%s"}\n' \
    "$state" "$merged" "$draft" "$base" "$head" "$user" "$a" "$MERGE_SHA"
}
export -f prj

ci_runs() { echo "{\"workflow_runs\":[{\"status\":\"$1\",\"conclusion\":${2:-null}}]}"; }
ci_checks() { echo "{\"check_runs\":[{\"name\":\"ci\",\"status\":\"completed\",\"conclusion\":\"$1\",\"started_at\":\"2026-11-27T10:00:00Z\"}]}"; }
RUNS="$R/actions/workflows/ci.yaml/runs?head_sha=$HEAD_SHA&event=pull_request&per_page=1"
CHECKS="$R/commits/$HEAD_SHA/check-runs?check_name=ci&per_page=100"
FREEZE="$R/actions/variables/MERGE_FREEZE"
REVERTS="$R/issues?state=open&labels=auto-rollback&per_page=20"
NOW_EPOCH=$(jq -rn '"2026-11-27T12:00:00Z" | fromdateiso8601')

setup() { # name: an open, up-to-date PR 7 with a green ci, auto-merge off
  export FAKE_GH_DIR="$tmp/$1"
  mkdir -p "$FAKE_GH_DIR"
  api_resp "$R/pulls/7" 200 "$(prj)"
  api_resp "$RUNS" 200 "$(ci_runs completed '"success"')"
  api_resp "$CHECKS" 200 "$(ci_checks success)"
  api_resp "$R/actions/variables?per_page=1" 200 '{"total_count":0,"variables":[]}'
  api_resp "$FREEZE" 404
  api_resp "$REVERTS" 200 '[]'
  api_resp user 200 '{"login":"ned-si"}'
}
pulls() { # <prj args, one string per read>...: successive reads of pulls/7
  local a=() s
  for s in "$@"; do
    # shellcheck disable=SC2086
    a+=(200 "$(prj $s)")
  done
  api_seq "$R/pulls/7" "${a[@]}"
}
run_merge() { # args... -> sets rc and out
  rc=0
  out=$(cd "$tmp/work" && PR_MERGE_NOW_EPOCH=$NOW_EPOCH bash "$REPO_ROOT/scripts/pr-merge.sh" "$@" 2>&1) || rc=$?
}
calls() { cat "$FAKE_GH_DIR/calls.log" 2>/dev/null || true; }
ncalls() { calls | grep -c -- "$1" || true; }
AUTO="pr merge 7 --repo ned-si/homelab --auto --squash --match-head-commit $HEAD_SHA"
no() { # name needle haystack
  case "$3" in *"$2"*) bad "$1 (unexpected '$2')" ;; *) ok "$1" ;; esac
}

echo "flow"
setup enabled
pulls "" "" "am=on" "state=closed merged=true"
run_merge 7
expect_eq "auto-merge enabled, then merged -> exit 0" 0 "$rc"
expect_contains "auto-merge enabled -> logged" "pr-merge: auto-merge on for PR #7 at ${HEAD_SHA:0:7}" "$out"
expect_contains "auto-merge enabled -> merged" "pr-merge: merged PR #7 as $MERGE_SHA" "$out"
expect_eq "auto-merge enabled -> requested once" 1 "$(ncalls "$AUTO")"
expect_contains "lock taken and released" "released the merge lock" "$out"

setup atonce
pulls "" "" "state=closed merged=true"
run_merge 7
expect_eq "merged at once by --auto -> exit 0" 0 "$rc"
expect_contains "merged at once -> merge sha" "pr-merge: merged PR #7 as $MERGE_SHA" "$out"

setup already
api_resp "$R/pulls/7" 200 "$(prj state=closed merged=true)"
run_merge 7
expect_eq "already merged -> exit 0" 0 "$rc"
expect_contains "already merged -> said so" "pr-merge: PR #7 already merged as $MERGE_SHA" "$out"
expect_eq "already merged -> no merge call" 0 "$(ncalls 'pr merge')"

echo "refusals"
refused() { # name needle [args...]
  local name=$1 needle=$2
  shift 2
  run_merge "$@"
  expect_eq "$name -> exit 2" 2 "$rc"
  expect_contains "$name -> refused" "$needle" "$out"
  expect_contains "$name -> nothing merged" "REFUSED PR #" "$out"
}
setup closed; api_resp "$R/pulls/7" 200 "$(prj state=closed)"
refused closed "refused: mergeable: state is closed" 7
setup draft; api_resp "$R/pulls/7" 200 "$(prj draft=true)"
refused draft "refused: mergeable: PR is a draft" 7
setup base; api_resp "$R/pulls/7" 200 "$(prj base=release)"
refused "wrong base" "refused: mergeable: base is release, not main" 7
setup freeze; api_resp "$FREEZE" 200 '{"name":"MERGE_FREEZE","value":"history rewrite in progress"}'
refused "freeze set" "refused: merge-freeze: MERGE_FREEZE is set: history rewrite in progress" 7
setup freeze500; api_resp "$FREEZE" 500 '{"message":"Server Error"}'
refused "freeze unreadable" "refused: merge-freeze: MERGE_FREEZE unreadable" 7
setup vars500; api_resp "$R/actions/variables?per_page=1" 500 '{"message":"Server Error"}'
refused "variables API error" "refused: merge-freeze: MERGE_FREEZE unreadable" 7
setup cifail
api_resp "$RUNS" 200 "$(ci_runs completed '"failure"')"
api_resp "$CHECKS" 200 "$(ci_checks failure)"
refused "ci failed" "refused: checks: ci is failure on ${HEAD_SHA:0:7}" 7
setup ff
refused "--ff" "refused: ff-protected: main is protected; squash only" --ff 7
expect_eq "refusals -> no merge call" 0 "$(ncalls 'pr merge')"

echo "freeze exemption"
setup allow7
api_resp "$FREEZE" 200 '{"name":"MERGE_FREEZE","value":"netpol break-glass (allow #7)"}'
pulls "" "" "state=closed merged=true"
run_merge 7
expect_eq "(allow #7) -> PR 7 merges" 0 "$rc"
expect_contains "(allow #7) -> logged" "MERGE_FREEZE is set (netpol break-glass (allow #7)); PR #7 is allowed" "$out"
api_resp "$R/pulls/8" 200 "$(prj)"
run_merge 8
expect_eq "(allow #7) -> PR 8 refused" 2 "$rc"
expect_contains "(allow #7) -> PR 8 reason" "MERGE_FREEZE is set: netpol break-glass (allow #7)" "$out"

echo "ci rerun"
setup rerun
api_seq "$RUNS" 200 "$(ci_runs in_progress)" 200 "$(ci_runs completed '"success"')"
api_resp "$CHECKS" 200 "$(ci_checks failure)"
run_merge --dry-run 7
expect_contains "rerun in progress, old ci failure -> pending" "refused: checks: ci is pending" "$out"
no "rerun in progress -> not failed" "ci is failure" "$out"
setup rerun-merge
api_seq "$RUNS" 200 "$(ci_runs in_progress)" 200 "$(ci_runs completed '"success"')"
pulls "" "" "" "state=closed merged=true"
run_merge 7
expect_eq "rerun passes -> merged" 0 "$rc"
expect_contains "rerun -> waited outside the lock" "waiting for ci on ${HEAD_SHA:0:7}" "$out"

echo "requesting the merge fails"
setup rc1-on
pulls "" "" "am=on" "state=closed merged=true"
rc=0; out=$(cd "$tmp/work" && FAKE_MERGE_RC=1 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "--auto fails, then on at the head -> exit 0" 0 "$rc"
expect_contains "--auto fails, then on -> merged" "merged PR #7 as $MERGE_SHA" "$out"
expect_eq "--auto fails, then on -> no direct merge" 0 "$(ncalls 'pr merge 7 --repo ned-si/homelab --squash')"
setup rc1-direct
pulls "" "" "" "state=closed merged=true"
rc=0; out=$(cd "$tmp/work" && FAKE_MERGE_RC=1 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "--auto fails, green and up to date -> direct merge, exit 0" 0 "$rc"
expect_eq "direct merge -> called" 1 "$(ncalls "pr merge 7 --repo ned-si/homelab --squash --match-head-commit $HEAD_SHA")"

echo "while waiting"
setup amoff
pulls "" "" ""
run_merge 7
expect_eq "auto-merge turned off by someone else -> exit 1" 1 "$rc"
expect_contains "auto-merge off -> said so" "auto-merge was turned off on PR #7; nothing merged" "$out"
setup amoff-behind
pulls "" "" ""
api_seq "$R/compare/main...$HEAD_SHA" 200 '{"behind_by":0,"base_commit":{"sha":"'"$OTHER_SHA"'"}}' \
  200 '{"behind_by":0,"base_commit":{"sha":"'"$OTHER_SHA"'"}}' 200 '{"behind_by":2,"base_commit":{"sha":"'"$OTHER_SHA"'"}}'
run_merge 7
expect_eq "auto-merge off on a behind PR -> exit 1" 1 "$rc"
no "auto-merge off on a behind PR -> no rebase" "rebasing" "$out"
expect_eq "auto-merge off on a behind PR -> not requested again" 1 "$(ncalls "$AUTO")"
expect_eq "auto-merge off on a behind PR -> nothing pushed" "$HEAD_SHA" "$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature)"
setup moved
pulls "" "" "am=on head=$OTHER_SHA"
run_merge 7
expect_eq "head moved by someone else -> exit 1" 1 "$rc"
expect_contains "head moved -> said so" "head moved to ${OTHER_SHA:0:7} by someone else" "$out"
setup freeze-wait
pulls "" "" "am=on"
api_seq "$FREEZE" 404 '{}' 404 '{}' 404 '{}' 200 '{"name":"MERGE_FREEZE","value":"stop"}'
run_merge 7
expect_eq "freeze set while waiting -> exit 2" 2 "$rc"
expect_contains "freeze set while waiting -> reason" "refused: merge-freeze: MERGE_FREEZE is set: stop" "$out"
expect_eq "freeze set while waiting -> auto-merge off" 1 "$(ncalls 'pr merge 7 --repo ned-si/homelab --disable-auto')"
setup freeze-wait-500
pulls "" "" "am=on"
api_seq "$FREEZE" 404 '{}' 404 '{}' 404 '{}' 500 '{"message":"Server Error"}'
run_merge 7
expect_eq "freeze unreadable while waiting -> exit 2" 2 "$rc"
expect_contains "freeze unreadable while waiting -> reason" "MERGE_FREEZE unreadable" "$out"
expect_eq "freeze unreadable while waiting -> auto-merge off" 1 "$(ncalls 'pr merge 7 --repo ned-si/homelab --disable-auto')"

echo "reverts"
revert() { # <number> <created_at>
  echo "[{\"number\":$1,\"created_at\":\"$2\",\"pull_request\":{\"url\":\"x\"}}]"
}
setup revert-young
api_seq "$REVERTS" 200 "$(revert 990 2026-11-27T11:50:00Z)" 200 '[]'
pulls "" "" "" "state=closed merged=true"
run_merge 7
expect_eq "young revert -> waited, then merged" 0 "$rc"
expect_contains "young revert -> logged" "waiting for the revert #990" "$out"
setup revert-stale
api_resp "$REVERTS" 200 "$(revert 991 2026-11-27T10:40:00Z)"
pulls "" "" "state=closed merged=true"
run_merge 7
expect_eq "stale revert -> merged" 0 "$rc"
expect_contains "stale revert -> logged" "ignoring stale revert #991 (opened 2026-11-27T10:40:00Z)" "$out"
setup revert-freeze
api_resp "$REVERTS" 200 "$(revert 990 2026-11-27T11:50:00Z)"
api_seq "$FREEZE" 404 '{}' 404 '{}' 200 '{"name":"MERGE_FREEZE","value":"stop"}'
run_merge 7
expect_eq "freeze set during the revert wait -> exit 2" 2 "$rc"
expect_contains "freeze set during the revert wait -> reason" "MERGE_FREEZE is set: stop" "$out"
expect_eq "freeze set during the revert wait -> no pr merge" 0 "$(ncalls 'pr merge')"

echo "dry run"
setup dry
run_merge --dry-run 7
expect_eq "dry run -> exit 0" 0 "$rc"
expect_contains "dry run -> would merge" "would merge (squash) PR #7 at $HEAD_SHA" "$out"
expect_eq "dry run -> no merge call" 0 "$(ncalls 'pr merge')"
no "dry run -> no lock" "merge lock" "$out"
setup dry-pending
api_resp "$RUNS" 200 '{"workflow_runs":[]}'
run_merge --dry-run 7
expect_contains "dry run, no ci run -> refused" "refused: checks: ci is missing" "$out"
run_merge --dry-run
expect_eq "no PR number -> usage" 64 "$rc"
rc=0; out=$(cd "$tmp/work" && PR_MERGE_POLL=x bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "bad PR_MERGE_POLL -> usage" 64 "$rc"
rc=0; out=$(cd "$tmp/work" && PR_MERGE_REPO='a b' bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "bad PR_MERGE_REPO -> usage" 64 "$rc"
rc=0; out=$(cd "$tmp/work" && PR_MERGE_REMOTE=nope bash "$REPO_ROOT/scripts/pr-merge.sh" --dry-run 7 2>&1) || rc=$?
expect_eq "unknown remote -> exit 1" 1 "$rc"

echo "gh hints (#1793)"
HINT='hint: use this instead of polling:
    gh event listen --resource x'
setup hint
printf '%s\n' "$HINT" > "$FAKE_GH_DIR/stderr-hint"
pulls "" "" "am=on" "state=closed merged=true"
run_merge 7
expect_eq "hint on every call -> merged" 0 "$rc"
expect_contains "hint on every call -> merge sha" "merged PR #7 as $MERGE_SHA" "$out"
run_merge --dry-run 7
expect_eq "hint on every call, dry run -> exit 0" 0 "$rc"
setup hint-stdout
api_resp "$R/pulls/7" nostatus 'hint: use this instead of polling'
rc=0; out=$(cd "$tmp/work" && PR_MERGE_READ_RETRIES=3 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "malformed value -> exit 1" 1 "$rc"
expect_contains "malformed value -> read error" "cannot read PR #7: unexpected value 'hint: use this instead of polling'" "$out"
expect_eq "malformed value -> READ_RETRIES reads" 3 "$(ncalls "api $R/pulls/7 ")"
setup hint-404
printf '%s\n' "$HINT" > "$FAKE_GH_DIR/stderr-hint"
api_resp "$R/pulls/7" stderr 'gh: Not Found (HTTP 404)'
rc=0; out=$(cd "$tmp/work" && PR_MERGE_READ_RETRIES=2 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "hint and 404 -> exit 1" 1 "$rc"
expect_contains "hint and 404 -> the real error" "cannot read PR #7: gh: Not Found (HTTP 404)" "$out"

echo "rebase"
# main moves ahead: the PR head no longer contains origin/main.
git -C "$tmp/work" checkout -q main
echo c > "$tmp/work/c"
git -C "$tmp/work" add c
git -C "$tmp/work" commit -q -m "chore: c"
git -C "$tmp/work" push -q origin main
git -C "$tmp/work" checkout -q feature
main_c=$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)

setup dry-behind
api_resp "$R/pulls/7" 200 "$(prj)"
run_merge --dry-run 7
expect_eq "dry run, behind -> exit 2" 2 "$rc"
expect_contains "dry run, behind -> rebase first" "refused: up-to-date: head does not contain main ${main_c:0:7}; rebase first" "$out"

setup signing
echo off > "$FAKE_GH_DIR/live"
cat > "$tmp/sign-stub" <<'EOF'
#!/bin/sh
echo "error: agent refused operation" >&2
exit 1
EOF
chmod +x "$tmp/sign-stub"
git -C "$tmp/work" config gpg.format ssh
git -C "$tmp/work" config commit.gpgsign true
git -C "$tmp/work" config user.signingkey "key::ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTests t@example.invalid"
git -C "$tmp/work" config gpg.ssh.program "$tmp/sign-stub"
run_merge 7
git -C "$tmp/work" config commit.gpgsign false
expect_eq "signing refused -> exit 2" 2 "$rc"
expect_contains "signing refused -> Bitwarden" "refused: up-to-date: signing failed (Bitwarden locked?)" "$out"
expect_eq "signing refused -> nothing pushed" "$HEAD_SHA" "$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature)"

setup rebase
echo on > "$FAKE_GH_DIR/live"
run_merge 7
expect_eq "behind -> rebased and merged" 0 "$rc"
expect_contains "behind -> rebasing" "pr-merge: rebasing feature onto origin/main ${main_c:0:7}" "$out"
new=$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature)
expect_contains "behind -> pushed" "pr-merge: pushed feature at $new" "$out"
expect_contains "behind -> auto-merge still on" "pr-merge: auto-merge already on for PR #7" "$out"
expect_eq "behind -> auto-merge not requested again" 0 "$(ncalls 'pr merge')"
expect_contains "behind -> merged" "merged PR #7 as $MERGE_SHA" "$out"
if git --git-dir="$ORIGIN" merge-base --is-ancestor "$main_c" refs/heads/feature; then
  ok "behind -> pushed branch contains main"
else
  bad "behind -> pushed branch contains main"
fi
expect_eq "behind -> rebase worktree removed" 1 "$(git -C "$tmp/work" worktree list | wc -l | tr -d ' ')"

echo "no porcelain"
expect_eq "no gh pr view or gh pr checks" "" \
  "$(grep -nE 'gh pr (view|checks)' "$REPO_ROOT/scripts/pr-merge.sh" "$REPO_ROOT/scripts/lib/merge_lock.sh" || true)"
expect_eq "no 2>&1 on a gh call" "" \
  "$(grep -nE '(^|[^A-Za-z0-9_])gh [^|]*2>&1' "$REPO_ROOT/scripts/pr-merge.sh" "$REPO_ROOT/scripts/lib/merge_lock.sh" || true)"

finish
