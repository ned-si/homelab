#!/bin/bash
# scripts/pr-merge.sh merge lock: acquire/release, stale-lock breaks, a bounded
# wait, two concurrent runs serialising, and the rebase inside the lock.
# Fake gh, a local git origin.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
install_fake_gh "$tmp/libbin"
export PR_MERGE_REPO=ned-si/homelab PR_MERGE_POLL=1
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
    echo "begin" >> "$d/merges.log"
    sleep "$FAKE_MERGE_SLEEP"
    echo "end" >> "$d/merges.log"
    echo "merged"; exit 0 ;;
esac
case "$*" in
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
