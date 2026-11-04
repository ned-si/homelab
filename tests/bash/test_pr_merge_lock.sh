#!/bin/bash
# scripts/pr-merge.sh merge lock: acquire/release, stale-lock breaks, a bounded
# wait, two concurrent runs serialising, the FIFO ticket queue (order, stale
# tickets, the wait counted from the ticket), and the rebase inside the lock.
# Fake gh, a local git origin.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
install_fake_gh "$tmp/libbin"
export PR_MERGE_REPO=ned-si/homelab PR_MERGE_POLL=1 PR_MERGE_LOCK_WAIT=60
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export ORIGIN="$tmp/origin.git" LIBGH="$tmp/libbin/gh"
export FAKE_GH_DIR="$tmp/gh" FAKE_AUTHOR=ned-si FAKE_MERGE_SLEEP=0
mkdir -p "$FAKE_GH_DIR"

# gh wrapper: `pr view` reads the PR head from the origin, `pr merge` records
# begin/end, ci check runs succeed; the rest goes to the shared fake.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
d=$FAKE_GH_DIR
case "$1 $2" in
  "pr view")
    echo "pr view" >> "$d/calls.log"
    h=$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature)
    printf '{"number":7,"title":"ci: add pinned CI gates for both repository layouts","state":"OPEN","isDraft":false,"baseRefName":"main","headRefName":"feature","headRefOid":"%s","mergeable":"MERGEABLE","isCrossRepository":false,"author":{"login":"%s"}}\n' "$h" "$FAKE_AUTHOR"
    exit 0 ;;
  "pr merge")
    echo "begin${FAKE_RUN:+ $FAKE_RUN}" >> "$d/merges.log"
    sleep "$FAKE_MERGE_SLEEP"
    echo "end${FAKE_RUN:+ $FAKE_RUN}" >> "$d/merges.log"
    [ "${FAKE_MERGE_RC:-0}" = 0 ] || exit "$FAKE_MERGE_RC"
    echo "merged"; exit 0 ;;
  "variable set"|"variable delete"|"workflow run")
    echo "$*" >> "$d/train.log"
    exit "${FAKE_VAR_RC:-0}" ;;
esac
case "$*" in
  "api --paginate repos/ned-si/homelab/pulls/7/commits")
    sleep "${FAKE_GUARD_SLEEP:-0}" ;;
  "api repos/ned-si/homelab/commits/"*"/check-runs"*)
    echo '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-10-16T00:00:00Z"}]}'
    exit 0 ;;
esac
exec "$LIBGH" "$@"
FAKE
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

api_resp "repos/ned-si/homelab/pulls/7/commits" 200 \
  '[{"sha":"0000000000000000000000000000000000000000","commit":{"message":"ci: add b","verification":{"verified":true,"reason":"valid"}}}]'
api_resp 'repos/ned-si/homelab/actions/variables?per_page=1' 200 '{"total_count":0,"variables":[]}'
api_resp 'repos/ned-si/homelab/actions/variables/MERGE_FREEZE' 404
api_resp 'user' 200 '{"login":"ned-si"}'
echo '[{"name":"ci","state":"SUCCESS","startedAt":"2026-10-04T07:00:00Z","link":"x"}]' > "$FAKE_GH_DIR/pr-checks.json"

# Origin: main at A, feature at B (child of A).
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

LOCK="$tmp/work/.git/pr-merge.lock"
run_merge() { # args... -> rc, out
  rc=0
  out=$(cd "$tmp/work" && bash "$REPO_ROOT/scripts/pr-merge.sh" "$@" 2>&1) || rc=$?
}
fake_owner() { # pid
  mkdir -p "$LOCK"
  printf 'pid=%s\npr=99\nbranch=other\nstarted=2026-10-16T00:00:00Z\n' "$1" > "$LOCK/owner"
}
merges() { [ -f "$FAKE_GH_DIR/merges.log" ] || return 0; tr '\n' ' ' < "$FAKE_GH_DIR/merges.log"; }

# --- acquire and release
rm -f "$FAKE_GH_DIR/merges.log"
run_merge 7
expect_eq "free lock -> merged, exit 0" 0 "$rc"
expect_contains "free lock -> took the lock" "took the merge lock $LOCK" "$out"
expect_contains "free lock -> released" "released the merge lock" "$out"
expect_contains "free lock -> merged" "merged PR #7 (squash)" "$out"
if [ -e "$LOCK" ]; then bad "lock dir removed after the merge"; else ok "lock dir removed after the merge"; fi

# --- the Renovate train is paused while the lock is held
train() { [ -f "$FAKE_GH_DIR/train.log" ] || return 0; sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z/<t>/' "$FAKE_GH_DIR/train.log" | tr '\n' '|'; }
TRAIN_OK="variable set RENOVATE_TRAIN_PAUSED --repo ned-si/homelab --body 7 <t>|workflow run renovate-next.yaml --repo ned-si/homelab|variable delete RENOVATE_TRAIN_PAUSED --repo ned-si/homelab|workflow run renovate-next.yaml --repo ned-si/homelab|"
rm -f "$FAKE_GH_DIR/train.log"
run_merge 7
expect_eq "merge -> paused, then resumed, train started each time" "$TRAIN_OK" "$(train)"
expect_contains "merge -> logs the pause" "paused the Renovate train (RENOVATE_TRAIN_PAUSED)" "$out"
expect_contains "merge -> logs the resume" "resumed the Renovate train" "$out"
case "$out" in
  *"paused the Renovate train"*"squash-merging"*"resumed the Renovate train"*"released the merge lock"*)
    ok "merge -> paused before the merge, resumed before the lock is released" ;;
  *) bad "merge -> paused before the merge, resumed before the lock is released" ;;
esac

rm -f "$FAKE_GH_DIR/train.log"
rc=0
out=$(cd "$tmp/work" && FAKE_MERGE_RC=1 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "failed merge -> exit 1" 1 "$rc"
expect_eq "failed merge -> the pause is still cleared" "$TRAIN_OK" "$(train)"
if [ -e "$LOCK" ]; then bad "failed merge -> lock released"; else ok "failed merge -> lock released"; fi

rm -f "$FAKE_GH_DIR/train.log"
rc=0
out=$(cd "$tmp/work" && PR_MERGE_PAUSE_REFRESH=0 FAKE_MERGE_RC=1 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_contains "refresh due -> the pause is set again" "variable set RENOVATE_TRAIN_PAUSED --repo ned-si/homelab --body 7 <t>|workflow run renovate-next.yaml --repo ned-si/homelab|variable set RENOVATE_TRAIN_PAUSED" "$(train)"

rm -f "$FAKE_GH_DIR/train.log"
rc=0
out=$(cd "$tmp/work" && FAKE_VAR_RC=1 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "variables API down -> still merges" 0 "$rc"
expect_contains "variables API down -> warns" "warning: cannot set RENOVATE_TRAIN_PAUSED; the Renovate train is not paused" "$out"
expect_eq "variables API down -> nothing to clear" "variable set RENOVATE_TRAIN_PAUSED --repo ned-si/homelab --body 7 <t>|" "$(train)"

rm -f "$FAKE_GH_DIR/train.log"
rc=0
out=$(cd "$tmp/work" && bash "$REPO_ROOT/scripts/pr-merge.sh" --dry-run 7 2>&1) || rc=$?
expect_eq "dry run -> the train is not touched" "" "$(train)"

# --- stale: owner pid gone
dead=$(bash -c 'echo $$')
fake_owner "$dead"
run_merge 7
expect_eq "dead owner -> merged" 0 "$rc"
expect_contains "dead owner -> lock broken" "breaking the merge lock held by PR #99 (other, pid $dead" "$out"
expect_contains "dead owner -> reason" "pid $dead is gone" "$out"
if [ -e "$LOCK" ]; then bad "broken lock released"; else ok "broken lock released"; fi

# --- stale: live owner, not refreshed for 30 min
fake_owner "$$"
touch -t 202001010000 "$LOCK/owner"
run_merge 7
expect_eq "old owner -> merged" 0 "$rc"
expect_contains "old owner -> reason" "not refreshed for over 30 min" "$out"

# --- held by a live owner: bounded wait, the holder's lock is left alone
fake_owner "$$"
rm -f "$FAKE_GH_DIR/merges.log"
rc=0
out=$(cd "$tmp/work" && PR_MERGE_LOCK_WAIT=2 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "live holder -> gives up, exit 1" 1 "$rc"
expect_contains "live holder -> logs the holder" "waiting for the merge lock, held by PR #99 (other, pid $$" "$out"
expect_contains "live holder -> gave up" "gave up after 0 min waiting for the merge lock" "$out"
expect_eq "live holder -> nothing merged" "" "$(merges)"
if [ -f "$LOCK/owner" ] && grep -q "^pid=$$\$" "$LOCK/owner"; then ok "live holder's lock kept"; else bad "live holder's lock kept"; fi
rm -rf "$LOCK"

# --- two concurrent runs serialise
rm -f "$FAKE_GH_DIR/merges.log"
export FAKE_MERGE_SLEEP=3
(cd "$tmp/work" && bash "$REPO_ROOT/scripts/pr-merge.sh" 7 > "$tmp/out.1" 2>&1; echo $? > "$tmp/rc.1") &
p1=$!
sleep 0.5
(cd "$tmp/work" && bash "$REPO_ROOT/scripts/pr-merge.sh" 7 > "$tmp/out.2" 2>&1; echo $? > "$tmp/rc.2") &
p2=$!
wait "$p1" "$p2"
export FAKE_MERGE_SLEEP=0
expect_eq "concurrent -> both exit 0" "0 0" "$(cat "$tmp/rc.1") $(cat "$tmp/rc.2")"
expect_eq "concurrent -> merges never overlap" "begin end begin end " "$(merges)"
expect_contains "concurrent -> the second waited" "waiting for the merge lock, held by PR #7 (feature" "$(cat "$tmp/out.1" "$tmp/out.2")"
if [ -e "$LOCK" ]; then bad "concurrent -> lock released"; else ok "concurrent -> lock released"; fi

# --- FIFO queue: runs take the lock in the order they took their tickets
QUEUE="$tmp/work/.git/pr-merge.queue"
queued() { [ -d "$QUEUE" ] || return 0; find "$QUEUE" -maxdepth 1 -type f -name '[0-9]*' -exec basename {} \; | grep -E '^[0-9]{10}$' | sort | tr '\n' ' ' || true; }
nqueued() { queued | wc -w | tr -d ' '; }
wait_queued() { # n: wait up to 30 s for n tickets
  local i=0
  while [ "$(nqueued)" -lt "$1" ] && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i + 1)); done
}
fake_ticket() { # number pid pr branch
  mkdir -p "$QUEUE"
  printf 'pid=%s\npr=%s\nbranch=%s\nticket=2026-11-04T00:00:00Z\n' "$2" "$3" "$4" > "$QUEUE/$1"
}

fake_owner "$$"
rm -f "$FAKE_GH_DIR/merges.log"
qpids=""
# The first run polls slowest: without the queue a later run would win.
for i in 1 2 3; do
  poll=1
  [ "$i" != 1 ] || poll=3
  (cd "$tmp/work" && FAKE_RUN=$i PR_MERGE_POLL=$poll bash "$REPO_ROOT/scripts/pr-merge.sh" 7 > "$tmp/q.$i" 2>&1; echo $? > "$tmp/qrc.$i") &
  qpids="$qpids $!"
  wait_queued "$i"
done
expect_eq "fifo -> three tickets queued" 3 "$(nqueued)"
rm -rf "$LOCK"
# shellcheck disable=SC2086
wait $qpids
expect_eq "fifo -> all exit 0" "0 0 0" "$(cat "$tmp/qrc.1") $(cat "$tmp/qrc.2") $(cat "$tmp/qrc.3")"
expect_eq "fifo -> merged in arrival order" "begin 1 end 1 begin 2 end 2 begin 3 end 3 " "$(merges)"
expect_contains "fifo -> the third run saw its place" "2 ahead (next PR #7)" "$(cat "$tmp/q.3")"
expect_eq "fifo -> no ticket left" "" "$(queued)"
if [ -e "$LOCK" ]; then bad "fifo -> lock released"; else ok "fifo -> lock released"; fi

# --- stale tickets ahead: a dead pid, a ticket not refreshed for 30 min
dead=$(bash -c 'echo $$')
fake_ticket 0000000001 "$dead" 98 gone
fake_ticket 0000000002 "$$" 97 asleep
touch -t 202001010000 "$QUEUE/0000000002"
rm -f "$FAKE_GH_DIR/merges.log"
run_merge 7
expect_eq "stale tickets -> merged" 0 "$rc"
expect_contains "dead pid -> ticket removed" "removing the stale ticket 0000000001 of PR #98 (gone): pid $dead is gone" "$out"
expect_contains "old ticket -> ticket removed" "removing the stale ticket 0000000002 of PR #97 (asleep): not refreshed for over 30 min" "$out"
expect_eq "stale tickets -> merged once" "begin end " "$(merges)"
expect_eq "stale tickets -> no ticket left" "" "$(queued)"

# --- a live ticket ahead and a free lock: wait for it, give up from our ticket
fake_ticket 0000000001 "$$" 96 first
rm -f "$FAKE_GH_DIR/merges.log"
rc=0
out=$(cd "$tmp/work" && PR_MERGE_LOCK_WAIT=2 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
expect_eq "ticket ahead -> gives up, exit 1" 1 "$rc"
expect_contains "ticket ahead -> took a ticket" "took ticket 00000000" "$out"
expect_contains "ticket ahead -> waits with the lock free" "waiting for the merge lock, not held; ticket " "$out"
expect_contains "ticket ahead -> names the next PR" "1 ahead (next PR #96)" "$out"
expect_contains "ticket ahead -> gave up" "gave up after 0 min waiting for the merge lock, not held" "$out"
expect_eq "ticket ahead -> nothing merged" "" "$(merges)"
expect_eq "ticket ahead -> only the live ticket is left" "0000000001 " "$(queued)"
if [ -e "$LOCK" ]; then bad "ticket ahead -> lock not taken"; else ok "ticket ahead -> lock not taken"; fi

# --- the wait counts from the ticket, not from the start of the run: the
# guards take 5 s before the ticket, the wait is 6 s, the ticket ahead goes
# away 7 s after the start.
rm -f "$FAKE_GH_DIR/merges.log"
(sleep 7; rm -f "$QUEUE/0000000001") &
gone=$!
rc=0
out=$(cd "$tmp/work" && FAKE_GUARD_SLEEP=5 PR_MERGE_LOCK_WAIT=6 bash "$REPO_ROOT/scripts/pr-merge.sh" 7 2>&1) || rc=$?
wait "$gone"
expect_eq "wait from the ticket -> merged" 0 "$rc"
expect_contains "wait from the ticket -> waited its turn" "1 ahead (next PR #96)" "$out"
expect_eq "wait from the ticket -> merged once" "begin end " "$(merges)"
expect_eq "wait from the ticket -> no ticket left" "" "$(queued)"

# --- behind main: rebase, push with lease, wait for ci, merge
git -C "$tmp/work" checkout -q main
echo c > "$tmp/work/c"
git -C "$tmp/work" add c
git -C "$tmp/work" commit -q -m "chore: c"
git -C "$tmp/work" push -q origin main
git -C "$tmp/work" checkout -q feature
main_c=$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)

export FAKE_AUTHOR=renovate
run_merge 7
expect_eq "behind, not ours -> exit 2" 2 "$rc"
expect_contains "behind, not ours -> refused" "not ours to rebase (author renovate)" "$out"
case "$out" in *"took the merge lock"*) bad "behind, not ours -> no lock taken" ;; *) ok "behind, not ours -> no lock taken" ;; esac

export FAKE_AUTHOR=ned-si
rm -f "$FAKE_GH_DIR/merges.log"
run_merge 7
expect_eq "behind -> merged" 0 "$rc"
expect_contains "behind -> rebased" "rebasing feature onto origin/main ${main_c:0:7}" "$out"
expect_contains "behind -> waited for ci" "ci passed on" "$out"
if git --git-dir="$ORIGIN" merge-base --is-ancestor "$main_c" refs/heads/feature; then
  ok "behind -> pushed branch contains main"
else
  bad "behind -> pushed branch contains main"
fi
expect_eq "behind -> merged once" "begin end " "$(merges)"
expect_eq "behind -> rebase worktree removed" "1" "$(git -C "$tmp/work" worktree list | wc -l | tr -d ' ')"

finish
