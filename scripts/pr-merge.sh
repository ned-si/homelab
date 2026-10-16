#!/bin/bash
# pr-merge.sh [--dry-run] [--ff] <pr-number>
#
# The only way code lands on `main` while branch protection is unavailable
# (private repository on GitHub Free, see the governance ADR). It refuses
# (exit 2, one line per failed guard) unless every guard holds:
#
#   checks         every required check reports SUCCESS for the PR head SHA
#   title          the PR title passes scripts/ci/check-title.sh
#   subjects       every commit subject passes scripts/ci/check-title.sh
#   verified       every commit is signed and verified by GitHub
#   up-to-date     origin/main is an ancestor of the PR head
#   mergeable      the PR is open, not a draft, targets main, and is MERGEABLE
#   merge-freeze   gh_var_state MERGE_FREEZE prints `absent`; `present` prints
#                  the variable's value as the reason, `error` refuses with
#                  "variables API unavailable" (fail closed)
#   ff-protected   (--ff only) main has no branch protection (HTTP 200 on the
#                  protection endpoint refuses; 403/404 = none)
#
# Then it squash-merges (`gh pr merge --squash --delete-branch
# --match-head-commit <sha>`), or with --ff pushes the verified head SHA to main
# as a fast-forward (`git push origin <sha>:refs/heads/main`, which the server
# rejects if it is not one). --dry-run prints the decision and changes nothing:
# "would merge (<mode>) PR #<n> at <sha>" on exit 0.
#
# Merge lock (not with --dry-run). `main` requires a strict, up-to-date `ci`
# and runs on this Mac merge from different worktrees, so merges are
# serialised:
#   1. Every guard runs once without the lock. Any refusal other than
#      up-to-date exits 2 at once; a pending `ci` is waited for.
#   2. It takes the lock `$(git rev-parse --git-common-dir)/pr-merge.lock`
#      (an atomic mkdir; `owner` records pid, PR, branch and start time).
#      A waiter logs the holder at most once a minute and gives up after
#      60 min (exit 1). A lock is broken when its owner pid is gone or its
#      owner file was not refreshed for 30 min (the holder refreshes it while
#      it waits for `ci`). EXIT, INT and TERM release it.
#   3. Inside the lock it re-runs every guard. If the head does not contain
#      origin/main, it rebases the head locally onto origin/main in a
#      throwaway worktree, pushes it with --force-with-lease (only a branch of
#      this repository authored by the gh user; never update-branch) and
#      waits for `ci` on the new head. Then it merges. If main moved again
#      (Renovate), it starts over inside the same lock, at most 3 times.
#
# Exit codes: 0 merged / would merge, 2 refused, 1 operational error (lock or
# ci wait timed out, main kept moving), 64 usage.
# Environment: GH_VAR_REPO / PR_MERGE_REPO (default ned-si/homelab),
# PR_MERGE_REMOTE (default origin), PR_MERGE_POLL (seconds between polls, 30),
# PR_MERGE_LOCK_WAIT (seconds, 3600), PR_MERGE_LOCK_STALE_MIN (minutes, 30),
# PR_MERGE_CI_TIMEOUT (seconds, 2700).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/gh_var.sh
. "$HERE/lib/gh_var.sh"
CHECK_TITLE="$HERE/ci/check-title.sh"

REPO=${PR_MERGE_REPO:-${GH_VAR_REPO:-ned-si/homelab}}
export GH_VAR_REPO=$REPO
REMOTE=${PR_MERGE_REMOTE:-origin}
# ci.yaml's aggregate `ci` job needs every other job and fails if any of them
# failed or did not run.
REQUIRED_CHECKS="ci"
POLL=${PR_MERGE_POLL:-30}
LOCK_WAIT=${PR_MERGE_LOCK_WAIT:-3600}
LOCK_STALE_MIN=${PR_MERGE_LOCK_STALE_MIN:-30}
CI_TIMEOUT=${PR_MERGE_CI_TIMEOUT:-2700}
MAX_RETRIES=3

dry_run=0
mode=squash
pr=""
usage() { echo "usage: $0 [--dry-run] [--ff] <pr-number>" >&2; exit 64; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --ff) mode=ff ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$pr" ] || usage; pr=$1 ;;
  esac
  shift
done
[[ "$pr" =~ ^[0-9]+$ ]] || usage

refusals=0
behind=0
pending=0
refuse() { # guard reason
  echo "refused: $1: $2"
  refusals=$((refusals + 1))
}
log() { echo "pr-merge: $*"; }
now() { date +%s; }

status_of() { # <gh api --include output> -> status or empty
  local first
  first=$(printf '%s\n' "$1" | head -n 1 | tr -d '\r')
  if [[ "$first" =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

# --- cleanup ------------------------------------------------------------------
LOCK_DIR=""
lock_held=0
rebase_wt=""
nap_pid=""
nap() { # seconds; interruptible by INT/TERM
  sleep "$1" &
  nap_pid=$!
  wait "$nap_pid" || true
  nap_pid=""
}
cleanup() {
  if [ -n "$nap_pid" ]; then kill "$nap_pid" 2>/dev/null || true; fi
  if [ -n "$rebase_wt" ]; then
    git -C "$rebase_wt" rebase --abort >/dev/null 2>&1 || true
    git worktree remove --force "$rebase_wt" >/dev/null 2>&1 || rm -rf "$rebase_wt"
    git worktree prune >/dev/null 2>&1 || true
    rebase_wt=""
  fi
  lock_release
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- merge lock -----------------------------------------------------------------
owner_field() { # name -> value from the lock's owner file
  sed -n "s/^$1=//p" "$LOCK_DIR/owner" 2>/dev/null | head -n 1
}
lock_holder() {
  if [ -f "$LOCK_DIR/owner" ]; then
    printf 'PR #%s (%s, pid %s, since %s)' "$(owner_field pr)" "$(owner_field branch)" \
      "$(owner_field pid)" "$(owner_field started)"
  else
    printf 'an unknown holder'
  fi
}
stale_reason=""
lock_stale() { # 0 when the current lock may be broken
  local pid
  if [ ! -f "$LOCK_DIR/owner" ]; then
    # mkdir and the owner write are microseconds apart: only an old dir is stale.
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      stale_reason="it has no owner file"
      return 0
    fi
    return 1
  fi
  pid=$(owner_field pid)
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    stale_reason="pid ${pid:-?} is gone"
    return 0
  fi
  if [ -n "$(find "$LOCK_DIR/owner" -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
    stale_reason="not refreshed for over $LOCK_STALE_MIN min"
    return 0
  fi
  return 1
}
lock_try_break() {
  # A second mkdir lock makes check-and-remove atomic between waiters.
  local brk="$LOCK_DIR.break"
  if [ -n "$(find "$brk" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$brk" 2>/dev/null || true; fi
  mkdir "$brk" 2>/dev/null || return 0
  if lock_stale; then
    log "breaking the merge lock held by $(lock_holder): $stale_reason"
    rm -rf "$LOCK_DIR"
  fi
  rmdir "$brk" 2>/dev/null || true
}
lock_acquire() { # branch
  local common start t last_log=0
  if ! common=$(git rev-parse --git-common-dir 2>/dev/null); then
    echo "pr-merge: run from inside the repository (the merge lock lives in its git dir)" >&2
    exit 1
  fi
  LOCK_DIR="$(cd "$common" && pwd)/pr-merge.lock"
  start=$(now)
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      lock_held=1
      printf 'pid=%s\npr=%s\nbranch=%s\nstarted=%s\n' "$$" "$pr" "$1" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_DIR/owner"
      log "took the merge lock $LOCK_DIR"
      return 0
    fi
    if lock_stale; then
      lock_try_break
      [ -d "$LOCK_DIR" ] || continue
    fi
    t=$(now)
    if [ $((t - start)) -ge "$LOCK_WAIT" ]; then
      echo "pr-merge: gave up after $(( (t - start) / 60 )) min waiting for the merge lock held by $(lock_holder); nothing merged" >&2
      exit 1
    fi
    if [ $((t - last_log)) -ge 60 ]; then
      log "waiting for the merge lock, held by $(lock_holder); waited $(( (t - start) / 60 )) min"
      last_log=$t
    fi
    nap "$POLL"
  done
}
lock_refresh() {
  if [ "$lock_held" = 1 ]; then touch "$LOCK_DIR/owner" 2>/dev/null || true; fi
}
lock_release() {
  if [ "$lock_held" = 1 ]; then
    # Never remove a lock another run took after breaking ours.
    if [ "$(owner_field pid)" = "$$" ]; then
      rm -rf "$LOCK_DIR"
      log "released the merge lock"
    fi
    lock_held=0
  fi
}

# --- PR metadata ------------------------------------------------------------
load_pr() {
  local tries=0
  while :; do
    if ! view=$(gh pr view "$pr" --repo "$REPO" \
          --json number,title,state,isDraft,baseRefName,headRefName,headRefOid,mergeable,isCrossRepository,author 2>&1); then
      echo "pr-merge: cannot read PR #$pr" >&2
      exit 1
    fi
    # GitHub computes mergeability lazily after a push.
    if [ "$dry_run" -eq 1 ] || [ "$tries" -ge 5 ] \
       || [ "$(jq -r '.mergeable' <<<"$view")" != "UNKNOWN" ]; then
      break
    fi
    tries=$((tries + 1))
    nap 3
  done
  title=$(jq -r '.title' <<<"$view")
  head=$(jq -r '.headRefOid' <<<"$view")
  branch=$(jq -r '.headRefName' <<<"$view")
  log "PR #$pr ($mode) head $head: $title"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "pr-merge: bad head SHA" >&2; exit 1; }
}

# --- guards -------------------------------------------------------------------
# Sets refusals, and for a real merge behind (head lacks main) and pending
# (`ci` not finished) instead of refusing for them.
run_guards() {
  local state draft base mergeable checks c st reason commits n sha verified subject val out
  refusals=0
  behind=0
  pending=0

  # mergeable
  state=$(jq -r '.state' <<<"$view")
  draft=$(jq -r '.isDraft' <<<"$view")
  base=$(jq -r '.baseRefName' <<<"$view")
  mergeable=$(jq -r '.mergeable' <<<"$view")
  [ "$state" = "OPEN" ] || refuse mergeable "state is $state"
  [ "$draft" = "false" ] || refuse mergeable "PR is a draft"
  [ "$base" = "main" ] || refuse mergeable "base is $base, not main"
  [ "$mergeable" = "MERGEABLE" ] || refuse mergeable "GitHub reports $mergeable"

  # checks
  if checks=$(gh pr checks "$pr" --repo "$REPO" --json name,state,startedAt,link 2>/dev/null) \
     || [ -n "${checks:-}" ]; then
    for c in $REQUIRED_CHECKS; do
      # The most recent run of each check name decides (older cancelled runs of
      # the same SHA are superseded).
      st=$(jq -r --arg n "$c" '[.[] | select(.name == $n)] | sort_by(.startedAt // "") | last | .state // "MISSING"' <<<"$checks" 2>/dev/null || echo MISSING)
      case "$st" in
        SUCCESS) ;;
        PENDING|QUEUED|IN_PROGRESS|WAITING|REQUESTED|EXPECTED|MISSING)
          if [ "$dry_run" -eq 1 ]; then refuse checks "$c is $st"; else pending=1; fi ;;
        *) refuse checks "$c is $st" ;;
      esac
    done
  else
    refuse checks "cannot read the PR checks"
  fi

  # title and subjects
  if ! reason=$("$CHECK_TITLE" "$title" 2>&1); then
    refuse title "$reason"
  fi
  if commits=$(gh api --paginate "repos/$REPO/pulls/$pr/commits" 2>/dev/null); then
    n=$(jq -s 'add | length' <<<"$commits")
    [ "$n" -gt 0 ] || refuse subjects "PR has no commits"
    while IFS=$'\t' read -r sha verified subject; do
      [ -n "$sha" ] || continue
      if ! reason=$("$CHECK_TITLE" "$subject" 2>&1); then
        refuse subjects "${sha:0:7} $reason"
      fi
      [ "$verified" = "true" ] || refuse verified "${sha:0:7} is not a verified signed commit"
    done < <(jq -rs 'add | .[] | [.sha, (.commit.verification.verified | tostring), (.commit.message | split("\n")[0])] | @tsv' <<<"$commits")
  else
    refuse subjects "cannot read the PR commits"
  fi

  # up-to-date
  main_sha=""
  if git fetch --quiet "$REMOTE" main "$head" 2>/dev/null; then
    main_sha=$(git rev-parse "refs/remotes/$REMOTE/main" 2>/dev/null || true)
    if [ -z "$main_sha" ]; then
      refuse up-to-date "cannot resolve $REMOTE/main"
    elif ! git merge-base --is-ancestor "$main_sha" "$head" 2>/dev/null; then
      if [ "$dry_run" -eq 1 ]; then
        refuse up-to-date "head does not contain $REMOTE/main ${main_sha:0:7}; rebase first"
      else
        behind=1
      fi
    fi
  else
    refuse up-to-date "cannot fetch $REMOTE main and the head commit"
  fi

  # merge-freeze
  case "$(gh_var_state MERGE_FREEZE)" in
    absent) ;;
    present)
      val=$(gh api "repos/$REPO/actions/variables/MERGE_FREEZE" --jq '.value' 2>/dev/null || echo "?")
      refuse merge-freeze "MERGE_FREEZE is set: ${val:0:200}" ;;
    *) refuse merge-freeze "variables API unavailable" ;;
  esac

  # ff-protected
  if [ "$mode" = "ff" ]; then
    out=$(gh api --include "repos/$REPO/branches/main/protection" 2>&1) || true
    st=$(status_of "$out")
    case "$st" in
      200) refuse ff-protected "main is protected; a direct fast-forward push would be rejected (use squash)" ;;
      403|404) ;;
      *) refuse ff-protected "cannot determine branch protection (status '${st:-none}')" ;;
    esac
  fi

  # Only rebase a branch of this repository that the gh user authored.
  if [ "$behind" -eq 1 ]; then
    local cross author me
    cross=$(jq -r '.isCrossRepository' <<<"$view")
    author=$(jq -r '.author.login // ""' <<<"$view")
    me=$(gh api user --jq '.login' 2>/dev/null || true)
    if [ "$cross" != "false" ] || [ -z "$me" ] || [ "$author" != "$me" ]; then
      refuse up-to-date "head does not contain $REMOTE/main ${main_sha:0:7} and the branch is not ours to rebase (author ${author:-?}); rebase it by hand"
    fi
  fi
}

refused_exit() {
  log "REFUSED PR #$pr ($refusals guard failure(s)); nothing merged"
  exit 2
}

# --- rebase and ci ------------------------------------------------------------
rebase_and_push() { # sets head to the rebased head
  local old=$head new
  rebase_wt=$(mktemp -d "${TMPDIR:-/tmp}/pr-merge-rebase.XXXXXX")
  git worktree add --quiet --detach "$rebase_wt" "$old"
  log "rebasing $branch onto $REMOTE/main ${main_sha:0:7}"
  if ! git -C "$rebase_wt" rebase --quiet "$main_sha"; then
    refuse up-to-date "rebase of $branch onto $REMOTE/main failed (conflict or signing); rebase it by hand"
    refused_exit
  fi
  new=$(git -C "$rebase_wt" rev-parse HEAD)
  if ! git -C "$rebase_wt" push --quiet --force-with-lease="refs/heads/$branch:$old" \
        "$REMOTE" "$new:refs/heads/$branch"; then
    echo "pr-merge: cannot push the rebased $branch (it changed on $REMOTE?)" >&2
    exit 1
  fi
  git worktree remove --force "$rebase_wt"
  rebase_wt=""
  log "pushed $branch at $new"
  head=$new
}

wait_for_ci() { # sha
  local sha=$1 deadline cur runs st
  deadline=$(( $(now) + CI_TIMEOUT ))
  log "waiting for ci on ${sha:0:7}"
  while :; do
    lock_refresh
    cur=$(gh pr view "$pr" --repo "$REPO" --json headRefOid 2>/dev/null | jq -r '.headRefOid' 2>/dev/null || true)
    if [ "$cur" = "$sha" ]; then
      runs=$(gh api "repos/$REPO/commits/$sha/check-runs?check_name=ci&per_page=100" 2>/dev/null || true)
      [ -n "$runs" ] || runs='{}'
      st=$(jq -r '[.check_runs[]? | select(.name == "ci")] | sort_by(.started_at // "") | last
                  | if . == null then "pending" elif .status != "completed" then "pending"
                    else (.conclusion // "unknown") end' <<<"$runs" 2>/dev/null || echo pending)
      case "$st" in
        success) log "ci passed on ${sha:0:7}"; return 0 ;;
        pending) ;;
        *) refuse checks "ci is $st on ${sha:0:7}"; refused_exit ;;
      esac
    fi
    if [ "$(now)" -ge "$deadline" ]; then
      echo "pr-merge: timed out after $((CI_TIMEOUT / 60)) min waiting for ci on ${sha:0:7}; nothing merged" >&2
      exit 1
    fi
    nap "$POLL"
  done
}

do_merge() {
  if [ "$mode" = "ff" ]; then
    log "fast-forwarding main to $head"
    git push "$REMOTE" "$head:refs/heads/main"
  else
    log "squash-merging PR #$pr at $head"
    gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --match-head-commit "$head"
  fi
}

# --- dry run: the decision only -----------------------------------------------
load_pr
run_guards
if [ "$dry_run" -eq 1 ]; then
  [ "$refusals" -eq 0 ] || refused_exit
  echo "would merge ($mode) PR #$pr at $head"
  exit 0
fi

# --- merge: fail fast, then serialise -------------------------------------------
[ "$refusals" -eq 0 ] || refused_exit
if [ "$pending" -eq 1 ] && [ "$behind" -eq 0 ]; then
  wait_for_ci "$head"
fi
lock_acquire "$branch"
rebases=0
while :; do
  lock_refresh
  load_pr
  run_guards
  [ "$refusals" -eq 0 ] || refused_exit
  if [ "$behind" -eq 1 ]; then
    if [ "$rebases" -gt "$MAX_RETRIES" ]; then
      echo "pr-merge: main kept moving: $rebases rebases of PR #$pr inside the lock; giving up, nothing merged" >&2
      exit 1
    fi
    rebases=$((rebases + 1))
    rebase_and_push
    wait_for_ci "$head"
    continue
  fi
  if [ "$pending" -eq 1 ]; then
    wait_for_ci "$head"
    continue
  fi
  if do_merge; then
    log "merged PR #$pr ($mode)"
    exit 0
  fi
  before=$main_sha
  git fetch --quiet "$REMOTE" main 2>/dev/null || true
  after=$(git rev-parse "refs/remotes/$REMOTE/main" 2>/dev/null || true)
  if [ -n "$after" ] && [ "$after" != "$before" ]; then
    log "main moved to ${after:0:7} during the merge; starting over"
    continue
  fi
  echo "pr-merge: merge of PR #$pr failed; nothing merged" >&2
  exit 1
done
