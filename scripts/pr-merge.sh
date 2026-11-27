#!/bin/bash
# pr-merge.sh [--dry-run] [--ff] <pr-number>
#
# Merges a pull request through GitHub auto-merge. It refuses (exit 2) a
# closed, draft or non-main pull request, a set or unreadable MERGE_FREEZE
# (unless its value ends with "(allow #<n>)" for this pull request) and a `ci`
# that completed without success. Then, inside the merge lock
# (scripts/lib/merge_lock.sh), it waits while an auto-rollback revert younger
# than PR_MERGE_REVERT_STALE_MIN is open, rebases the branch locally when it is
# behind main (signed with the operator's key; never update-branch), turns on
# `gh pr merge --auto --squash --match-head-commit` and polls until GitHub has
# merged it. GitHub is read only through `gh api --jq`, every value validated.
# Why it works this way: docs/decisions.md#squash-merge.
#
# --dry-run prints "would merge (squash) PR #<n> at <sha>" and changes nothing.
# --ff always refuses: main is protected.
#
# Exit codes: 0 merged / would merge, 2 refused, 1 operational error, 64 usage.
# Environment (defaults): PR_MERGE_REPO / GH_VAR_REPO (ned-si/homelab),
# PR_MERGE_REMOTE (origin), PR_MERGE_POLL (30 s), PR_MERGE_LOCK_WAIT (3600 s),
# PR_MERGE_LOCK_STALE_MIN (30), PR_MERGE_CI_TIMEOUT (2700 s),
# PR_MERGE_READ_RETRIES (5), PR_MERGE_REVERT_STALE_MIN (70) and
# PR_MERGE_NOW_EPOCH (tests only).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/gh_var.sh
. "$HERE/lib/gh_var.sh"
# shellcheck source=scripts/lib/merge_lock.sh
. "$HERE/lib/merge_lock.sh"
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1

usage() { echo "usage: $0 [--dry-run] [--ff] <pr-number>" >&2; exit 64; }
knob() { # <name> <value> <min> [max]: exit 64 unless an integer in range
  if ! [[ "$2" =~ ^[0-9]{1,12}$ ]] || [ "$((10#$2))" -lt "$3" ] \
     || { [ -n "${4:-}" ] && [ "$((10#$2))" -gt "$4" ]; }; then
    echo "pr-merge: $1 must be an integer >= $3${4:+ and <= $4}, not '$2'" >&2
    usage
  fi
}

dry_run=0
ff=0
pr=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --ff) ff=1 ;;
    -*) usage ;;
    *) [ -z "$pr" ] || usage; pr=$1 ;;
  esac
  shift
done
[[ "$pr" =~ ^[0-9]+$ ]] || usage

RE_REPO='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
RE_REF='^[A-Za-z0-9._/-]+$'
RE_SHA='^[0-9a-f]{40}$'
RE_LOGIN='^[A-Za-z0-9-]+(\[bot\])?$'
RE_TIME='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
RE_ALLOW='\(allow #([0-9]+)\)$'

REPO=${PR_MERGE_REPO:-${GH_VAR_REPO:-ned-si/homelab}}
[[ "$REPO" =~ $RE_REPO ]] || { echo "pr-merge: PR_MERGE_REPO must be owner/name, not '$REPO'" >&2; usage; }
export GH_VAR_REPO=$REPO
REMOTE=${PR_MERGE_REMOTE:-origin}
POLL=${PR_MERGE_POLL:-30}
LOCK_WAIT=${PR_MERGE_LOCK_WAIT:-3600}
LOCK_STALE_MIN=${PR_MERGE_LOCK_STALE_MIN:-30}
CI_TIMEOUT=${PR_MERGE_CI_TIMEOUT:-2700}
READ_RETRIES=${PR_MERGE_READ_RETRIES:-5}
REVERT_STALE_MIN=${PR_MERGE_REVERT_STALE_MIN:-70}
knob PR_MERGE_POLL "$POLL" 0 600
knob PR_MERGE_LOCK_WAIT "$LOCK_WAIT" 0
knob PR_MERGE_LOCK_STALE_MIN "$LOCK_STALE_MIN" 1
knob PR_MERGE_CI_TIMEOUT "$CI_TIMEOUT" 0
knob PR_MERGE_READ_RETRIES "$READ_RETRIES" 1
knob PR_MERGE_REVERT_STALE_MIN "$REVERT_STALE_MIN" 1
[ -z "${PR_MERGE_NOW_EPOCH:-}" ] || knob PR_MERGE_NOW_EPOCH "$PR_MERGE_NOW_EPOCH" 0
MAX_RETRIES=3

refusals=0
refuse() { # guard reason
  echo "refused: $1: $2"
  refusals=$((refusals + 1))
}
refused_exit() {
  log "REFUSED PR #$pr ($refusals guard failure(s)); nothing merged"
  exit 2
}
log() { echo "pr-merge: $*"; }
fail() { echo "pr-merge: $*" >&2; exit 1; }
now() { date +%s; }
epoch_now() { if [ -n "${PR_MERGE_NOW_EPOCH:-}" ]; then echo "$PR_MERGE_NOW_EPOCH"; else date +%s; fi; }

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  fail "PR_MERGE_REMOTE '$REMOTE' is not a git remote here"
fi

# --- cleanup ------------------------------------------------------------------
LOCK_DIR=""
lock_held=0
QUEUE_DIR=""
ticket=""
rebase_wt=""
nap_pid=""
errlog=$(mktemp "${TMPDIR:-/tmp}/pr-merge-err.XXXXXX")
rebase_log=$(mktemp "${TMPDIR:-/tmp}/pr-merge-rebase-err.XXXXXX")
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
  rm -f "$errlog" "$rebase_log"
  ticket_drop
  lock_release
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- reading GitHub -------------------------------------------------------------
# stdout is the value, stderr goes to $errlog (this call only); `why` is its
# last line that is not part of a gh hint (#1793).
out=""
rc=0
why=""
gh_err() {
  why=$({ grep -v -e '^hint:' -e '^[[:space:]]' "$errlog" || true; } | tail -n 1 | cut -c1-200)
}
api() { # <route> <jq>
  : > "$errlog"
  rc=0
  out=$(gh api "$1" --jq "$2" 2>"$errlog") || rc=$?
  gh_err
  [ -n "$why" ] || why="gh exited $rc"
}
read_what=""
read_why=""
unreadable() { # <what>: a read error
  read_what=$1
  if [ "$rc" != 0 ]; then read_why=$why; else read_why="unexpected value '${out:0:80}'"; fi
  return 1
}
got() { [ "$rc" = 0 ] && [ -n "$out" ] && [[ "$out" != *$'\n'* ]]; } # one value read
read_errors=0
reader() { # <read function> [args]: a read error is retried, READ_RETRIES in a row
  while :; do
    if "$@"; then
      read_errors=0
      return 0
    fi
    read_errors=$((read_errors + 1))
    if [ "$read_errors" -ge "$READ_RETRIES" ]; then
      fail "cannot read $read_what: $read_why"
    fi
    log "read error $read_errors/$READ_RETRIES: $read_what: $read_why; retrying"
    nap "$POLL"
  done
}

read_pr() { # sets pr_state pr_merged pr_draft pr_base pr_ref pr_head pr_repo pr_user pr_am pr_merge_sha
  local rest
  api "repos/$REPO/pulls/$pr" '[.state, (.merged | tostring), (.draft | tostring), .base.ref, .head.ref, .head.sha,
    (.head.repo.full_name // "-"), .user.login, (if .auto_merge == null then "off" else "on" end),
    (.merge_commit_sha // "-")] | map(if . == null or . == "" then "-" else . end) | @tsv'
  got || { unreadable "PR #$pr"; return 1; }
  IFS=$'\t' read -r pr_state pr_merged pr_draft pr_base pr_ref pr_head pr_repo pr_user pr_am pr_merge_sha rest <<<"$out"
  if [ -n "$rest" ] \
     || ! [[ "$pr_state" =~ ^(open|closed)$ ]] || ! [[ "$pr_merged" =~ ^(true|false)$ ]] \
     || ! [[ "$pr_draft" =~ ^(true|false)$ ]] || ! [[ "$pr_base" =~ $RE_REF ]] \
     || ! [[ "$pr_ref" =~ $RE_REF ]] || ! [[ "$pr_head" =~ $RE_SHA ]] \
     || { [ "$pr_repo" != - ] && ! [[ "$pr_repo" =~ $RE_REPO ]]; } \
     || ! [[ "$pr_user" =~ $RE_LOGIN ]] || ! [[ "$pr_am" =~ ^(on|off)$ ]] \
     || { [ "$pr_merged" = true ] && ! [[ "$pr_merge_sha" =~ $RE_SHA ]]; }; then
    unreadable "PR #$pr"
    return 1
  fi
}

ci="" # missing, pending, or a conclusion
ci_state() { # <sha>: pending from the workflow run, the conclusion from the check run
  local st concl rest
  api "repos/$REPO/actions/workflows/ci.yaml/runs?head_sha=$1&event=pull_request&per_page=1" \
    '.workflow_runs[0] | if . == null then "missing" else "\(.status)\t\(.conclusion // "-")" end'
  got || { unreadable "the ci workflow run on ${1:0:7}"; return 1; }
  if [ "$out" = missing ]; then ci=missing; return 0; fi
  IFS=$'\t' read -r st concl rest <<<"$out"
  [ -z "$rest" ] || { unreadable "the ci workflow run on ${1:0:7}"; return 1; }
  case "$st" in
    queued | in_progress | waiting | requested | pending) ci=pending; return 0 ;;
    completed) ;;
    *) unreadable "the ci workflow run on ${1:0:7}"; return 1 ;;
  esac
  api "repos/$REPO/commits/$1/check-runs?check_name=ci&per_page=100" \
    '[.check_runs[]? | select(.name == "ci")] | sort_by(.started_at // "") | last
     | if . == null then "none" elif .status != "completed" then "pending" else (.conclusion // "-") end'
  got || { unreadable "the ci check run on ${1:0:7}"; return 1; }
  [ "$out" != none ] || out=$concl
  case "$out" in
    pending | success | failure | cancelled | timed_out | action_required | neutral | skipped | stale | startup_failure)
      ci=$out ;;
    *) unreadable "the ci check run on ${1:0:7}"; return 1 ;;
  esac
}

behind=0
main_tip=""
behind_by() { # <sha>: sets behind and main_tip
  api "repos/$REPO/compare/main...$1" '"\(.behind_by) \(.base_commit.sha)"'
  got && [[ "$out" =~ ^[0-9]+\ [0-9a-f]{40}$ ]] \
    || { unreadable "how far ${1:0:7} is behind main"; return 1; }
  behind=${out%% *}
  main_tip=${out##* }
}

reverts="" # lines "<number> <created_at>"
open_reverts() {
  local line n t
  api "repos/$REPO/issues?state=open&labels=auto-rollback&per_page=20" \
    '.[] | select(.pull_request != null) | "\(.number)\t\(.created_at)"'
  [ "$rc" = 0 ] || { unreadable "the open auto-rollback reverts"; return 1; }
  reverts=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r n t <<<"$line"
    [[ "$n" =~ ^[0-9]+$ ]] && [[ "$t" =~ $RE_TIME ]] || { unreadable "the open auto-rollback reverts"; return 1; }
    [ "$n" = "$pr" ] || reverts="$reverts$n $t"$'\n'
  done <<<"$out"
}

me=""
read_me() {
  api user '.login'
  got && [[ "$out" =~ $RE_LOGIN ]] || { unreadable "the gh user"; return 1; }
  me=$out
}

freeze_reason=""
freeze_logged=0
freeze_ok() { # 0 when no freeze holds this pull request; else sets freeze_reason
  local val
  case "$(gh_var_state MERGE_FREEZE)" in
    absent) return 0 ;;
    present) ;;
    *) freeze_reason="MERGE_FREEZE unreadable"; return 1 ;;
  esac
  api "repos/$REPO/actions/variables/MERGE_FREEZE" '.value // ""'
  if [ "$rc" != 0 ] || [ -z "$out" ]; then freeze_reason="MERGE_FREEZE unreadable"; return 1; fi
  val=$out
  if [[ "$val" =~ $RE_ALLOW ]] && [ "${BASH_REMATCH[1]}" = "$pr" ]; then
    [ "$freeze_logged" = 1 ] || log "MERGE_FREEZE is set ($val); PR #$pr is allowed"
    freeze_logged=1
    return 0
  fi
  freeze_reason="MERGE_FREEZE is set: ${val:0:200}"
  return 1
}

# --- guards -------------------------------------------------------------------
head=""
am_seen=0
pushed=0
check_pr() { # read the PR, ci and behind; exit on a refusal or when merged
  refusals=0
  reader read_pr
  if [ "$pr_merged" = true ]; then
    log "PR #$pr already merged as $pr_merge_sha"
    exit 0
  fi
  if [ "$pr_head" != "$head" ]; then
    # Our own push or auto-merge pins the head; before that, follow it.
    if [ -n "$head" ] && { [ "$am_seen" = 1 ] || [ "$pushed" = 1 ]; }; then
      fail "head moved to ${pr_head:0:7} by someone else; nothing merged"
    fi
    head=$pr_head
    log "PR #$pr ($pr_ref) head $head"
  fi
  if [ "$am_seen" = 1 ] && [ "$pr_am" = off ]; then
    fail "auto-merge was turned off on PR #$pr; nothing merged"
  fi
  [ "$pr_state" = open ] || refuse mergeable "state is $pr_state"
  [ "$pr_draft" = false ] || refuse mergeable "PR is a draft"
  [ "$pr_base" = main ] || refuse mergeable "base is $pr_base, not main"
  freeze_ok || refuse merge-freeze "$freeze_reason"
  reader ci_state "$head"
  case "$ci" in
    success | pending | missing) ;;
    *) refuse checks "ci is $ci on ${head:0:7}" ;;
  esac
  reader behind_by "$head"
  if [ "$dry_run" = 0 ] && [ "$behind" -gt 0 ]; then
    [ -n "$me" ] || reader read_me
    if [ "$pr_repo" != "$REPO" ] || [ "$pr_user" != "$me" ]; then
      refuse up-to-date "head does not contain main ${main_tip:0:7} and the branch is not ours to rebase (author $pr_user); rebase it by hand"
    fi
  fi
  [ "$refusals" -eq 0 ] || refused_exit
}

disable_auto() {
  : > "$errlog"
  if ! gh pr merge "$pr" --repo "$REPO" --disable-auto >/dev/null 2>"$errlog"; then
    gh_err
    log "warning: cannot turn auto-merge off on PR #$pr: $why"
  fi
}

# --- rebase ---------------------------------------------------------------------
main_sha=""
rebase_and_push() { # sets head to the rebased head
  local old=$head new
  git fetch --quiet "$REMOTE" main "$old" 2>/dev/null || fail "cannot fetch $REMOTE main and the head commit"
  main_sha=$(git rev-parse "refs/remotes/$REMOTE/main")
  rebase_wt=$(mktemp -d "${TMPDIR:-/tmp}/pr-merge-rebase.XXXXXX")
  git worktree add --quiet --detach "$rebase_wt" "$old"
  log "rebasing $pr_ref onto $REMOTE/main ${main_sha:0:7}"
  : > "$rebase_log"
  if ! git -C "$rebase_wt" rebase --quiet "$main_sha" 2>"$rebase_log"; then
    cat "$rebase_log" >&2
    if grep -q 'agent refused operation' "$rebase_log"; then
      refuse up-to-date "signing failed (Bitwarden locked?)"
    else
      refuse up-to-date "rebase onto main failed; rebase it by hand"
    fi
    refused_exit
  fi
  new=$(git -C "$rebase_wt" rev-parse HEAD)
  if ! git -C "$rebase_wt" push --quiet --force-with-lease="refs/heads/$pr_ref:$old" \
        "$REMOTE" "$new:refs/heads/$pr_ref"; then
    fail "cannot push the rebased $pr_ref (it changed on $REMOTE?)"
  fi
  git worktree remove --force "$rebase_wt"
  rebase_wt=""
  log "pushed $pr_ref at $new"
  head=$new
  pushed=1
}

# GitHub updates the pull request a moment after a push.
wait_head() { # <old head>
  local deadline=$(( $(now) + CI_TIMEOUT ))
  while :; do
    reader read_pr
    [ "$pr_head" != "$1" ] || [ "$pr_merged" = true ] || {
      [ "$(now)" -lt "$deadline" ] || fail "PR #$pr still shows ${1:0:7} after the push"
      nap "$POLL"
      continue
    }
    return 0
  done
}

# --- request the merge (flow step 6.4) ---------------------------------------
request_merge() {
  local mwhy
  if [ "$pr_merged" = true ]; then log "merged PR #$pr as $pr_merge_sha"; exit 0; fi
  if [ "$pr_head" != "$head" ]; then fail "head moved to ${pr_head:0:7} by someone else; nothing merged"; fi
  if [ "$pr_am" = on ]; then
    am_seen=1
    log "auto-merge already on for PR #$pr"
    return 0
  fi
  [ "$am_seen" = 0 ] || fail "auto-merge was turned off on PR #$pr; nothing merged"
  if ! freeze_ok; then refuse merge-freeze "$freeze_reason"; refused_exit; fi
  : > "$errlog"
  if gh pr merge "$pr" --repo "$REPO" --auto --squash --match-head-commit "$head" >/dev/null 2>"$errlog"; then
    am_seen=1
    log "auto-merge on for PR #$pr at ${head:0:7}"
    return 0
  fi
  gh_err
  mwhy=$why
  reader read_pr
  if [ "$pr_merged" = true ]; then log "merged PR #$pr as $pr_merge_sha"; exit 0; fi
  if [ "$pr_am" = on ] && [ "$pr_head" = "$head" ]; then
    am_seen=1
    log "auto-merge on for PR #$pr at ${head:0:7}"
    return 0
  fi
  reader ci_state "$head"
  reader behind_by "$head"
  if [ "$pr_head" = "$head" ] && [ "$behind" -eq 0 ] && [ "$ci" = success ]; then
    if ! freeze_ok; then refuse merge-freeze "$freeze_reason"; refused_exit; fi
    log "cannot enable auto-merge ($mwhy); squash-merging PR #$pr at ${head:0:7}"
    : > "$errlog"
    gh pr merge "$pr" --repo "$REPO" --squash --match-head-commit "$head" >/dev/null 2>"$errlog" || true
    gh_err
    reader read_pr
    if [ "$pr_merged" = true ]; then log "merged PR #$pr as $pr_merge_sha"; exit 0; fi
    fail "cannot merge PR #$pr: ${why:-not merged}"
  fi
  fail "cannot enable auto-merge: $mwhy"
}

# --- poll (flow step 7): returns when behind main again, else exits ---------------------------------
poll() {
  local deadline=$(( $(now) + CI_TIMEOUT ))
  while :; do
    nap "$POLL"
    lock_refresh
    reader read_pr
    if [ "$pr_merged" = true ]; then log "merged PR #$pr as $pr_merge_sha"; exit 0; fi
    if [ "$pr_state" != open ]; then refuse mergeable "state is $pr_state"; refused_exit; fi
    if [ "$pr_head" != "$head" ]; then fail "head moved to ${pr_head:0:7} by someone else; nothing merged"; fi
    if ! freeze_ok; then
      disable_auto
      refuse merge-freeze "$freeze_reason"
      refused_exit
    fi
    reader ci_state "$head"
    case "$ci" in
      success | pending | missing) ;;
      *) refuse checks "ci is $ci on ${head:0:7}"; refused_exit ;;
    esac
    [ "$pr_am" = on ] || fail "auto-merge was turned off on PR #$pr; nothing merged"
    reader behind_by "$head"
    [ "$behind" -eq 0 ] || return 0
    if [ "$(now)" -ge "$deadline" ]; then
      fail "timed out after $((CI_TIMEOUT / 60)) min waiting for ci on ${head:0:7}; auto-merge stays on"
    fi
  done
}

# --- the revert wait (flow step 6.2): 0 = waited one poll ----------------------
stale_seen=" "
revert_since=""
revert_logged=0
revert_wait() {
  local n t age young=""
  reader open_reverts
  while read -r n t; do
    [ -n "$n" ] || continue
    age=$(( $(epoch_now) - $(jq -rn --arg t "$t" '$t | fromdateiso8601') ))
    if [ "$age" -ge $((REVERT_STALE_MIN * 60)) ]; then
      case "$stale_seen" in
        *" $n "*) ;;
        *) log "ignoring stale revert #$n (opened $t)"; stale_seen="$stale_seen$n " ;;
      esac
    elif [ -z "$young" ]; then
      young=$n
    fi
  done <<<"$reverts"
  if [ -z "$young" ]; then
    revert_since=""
    return 1
  fi
  [ -n "$revert_since" ] || revert_since=$(now)
  if [ $(( $(now) - revert_since )) -ge "$CI_TIMEOUT" ]; then
    fail "gave up after $((CI_TIMEOUT / 60)) min waiting for the revert #$young; nothing merged"
  fi
  if [ $(( $(now) - revert_logged )) -ge 60 ]; then
    log "waiting for the revert #$young"
    revert_logged=$(now)
  fi
  lock_refresh
  nap "$POLL"
  return 0
}

# --- flow -----------------------------------------------------------------------
if [ "$ff" = 1 ]; then
  refuse ff-protected "main is protected; squash only"
  refused_exit
fi

check_pr
if [ "$dry_run" = 1 ]; then
  case "$ci" in success) ;; *) refuse checks "ci is $ci" ;; esac
  [ "$behind" -eq 0 ] || refuse up-to-date "head does not contain main ${main_tip:0:7}; rebase first"
  [ "$refusals" -eq 0 ] || refused_exit
  echo "would merge (squash) PR #$pr at $head"
  exit 0
fi

# A failing ci refuses before the run queues for the lock.
if [ "$behind" -eq 0 ] && [ "$ci" != success ]; then
  deadline=$(( $(now) + CI_TIMEOUT ))
  log "waiting for ci on ${head:0:7}"
  while [ "$behind" -eq 0 ] && [ "$ci" != success ]; do
    [ "$(now)" -lt "$deadline" ] || fail "timed out after $((CI_TIMEOUT / 60)) min waiting for ci on ${head:0:7}; nothing merged"
    nap "$POLL"
    check_pr
  done
fi

lock_acquire "$pr_ref"
rebases=0
while :; do
  lock_refresh
  check_pr
  if revert_wait; then continue; fi
  if [ "$behind" -gt 0 ]; then
    if [ "$rebases" -gt "$MAX_RETRIES" ]; then
      fail "main kept moving: $rebases rebases of PR #$pr inside the lock; giving up"
    fi
    rebases=$((rebases + 1))
    old=$head
    rebase_and_push
    wait_head "$old"
  fi
  request_merge
  poll
done
