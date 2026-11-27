# shellcheck shell=bash
# shellcheck disable=SC2154
#
# merge_lock.sh -- the merge lock and FIFO ticket queue of scripts/pr-merge.sh,
# in $(git rev-parse --git-common-dir): `pr-merge.lock` (an atomic mkdir,
# `owner` records pid, PR, branch and start time) and `pr-merge.queue/` (one
# ticket per waiter, numbered from the `seq` counter). Only the oldest ticket
# takes the lock. A waiter gives up LOCK_WAIT seconds after its ticket; a
# ticket or a lock is stale when its pid is gone or it was not refreshed for
# LOCK_STALE_MIN minutes.
#
# The caller provides pr, POLL, LOCK_WAIT, LOCK_STALE_MIN, log, nap and now,
# and the globals lock_held, LOCK_DIR, QUEUE_DIR and ticket.

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
# --- merge queue ------------------------------------------------------------------
# Ticket names are the counter value, zero-padded, so a sorted glob is the
# queue order.
TICKET_GLOB='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
ticket_branch=""
ticket_started=""
ahead=0
ahead_pr=""
ticket_field() { # file name -> value
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}
ticket_write() {
  local tmp="$QUEUE_DIR/.$ticket.$$"
  mkdir -p "$QUEUE_DIR"
  printf 'pid=%s\npr=%s\nbranch=%s\nticket=%s\n' "$$" "$pr" "$ticket_branch" \
    "$ticket_started" > "$tmp"
  mv -f "$tmp" "$QUEUE_DIR/$ticket"
}
ticket_take() { # branch
  local mutex="$QUEUE_DIR/seq.lock" n t last
  mkdir -p "$QUEUE_DIR"
  # The counter is read and bumped under a short mkdir mutex.
  while ! mkdir "$mutex" 2>/dev/null; do
    if [ -n "$(find "$mutex" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$mutex" 2>/dev/null || true
    else
      sleep 0.2
    fi
  done
  n=$(cat "$QUEUE_DIR/seq" 2>/dev/null || true)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((10#$n))
  # Never below a ticket still queued, even if `seq` was lost.
  last=""
  for t in "$QUEUE_DIR"/$TICKET_GLOB; do [ -f "$t" ] && last=$(basename "$t"); done
  if [ -n "$last" ] && [ $((10#$last)) -gt "$n" ]; then n=$((10#$last)); fi
  n=$((n + 1))
  echo "$n" > "$QUEUE_DIR/seq"
  ticket=$(printf '%010d' "$n")
  ticket_branch=$1
  ticket_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ticket_write
  rmdir "$mutex" 2>/dev/null || true
}
ticket_refresh() {
  if [ -f "$QUEUE_DIR/$ticket" ]; then
    touch "$QUEUE_DIR/$ticket" 2>/dev/null || true
  else
    log "ticket $ticket was removed from the queue; restoring it"
    ticket_write
  fi
}
ticket_drop() {
  if [ -n "$ticket" ]; then
    rm -f "$QUEUE_DIR/$ticket"
    ticket=""
  fi
}
queue_clean() { # removes the stale tickets of other runs
  local t name pid reason
  for t in "$QUEUE_DIR"/$TICKET_GLOB; do
    [ -f "$t" ] || continue
    name=$(basename "$t")
    [ "$name" != "$ticket" ] || continue
    pid=$(ticket_field "$t" pid)
    reason=""
    if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      reason="pid ${pid:-?} is gone"
    elif [ -n "$(find "$t" -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
      reason="not refreshed for over $LOCK_STALE_MIN min"
    fi
    if [ -n "$reason" ]; then
      log "removing the stale ticket $name of PR #$(ticket_field "$t" pr) ($(ticket_field "$t" branch)): $reason"
      rm -f "$t"
    fi
  done
}
queue_scan() { # sets ahead (tickets before ours) and ahead_pr (the oldest one's PR)
  local t
  ahead=0
  ahead_pr=""
  for t in "$QUEUE_DIR"/$TICKET_GLOB; do
    [ -f "$t" ] || continue
    [[ "$(basename "$t")" < "$ticket" ]] || break
    [ "$ahead" -gt 0 ] || ahead_pr=$(ticket_field "$t" pr)
    ahead=$((ahead + 1))
  done
}
queue_status() {
  local held="not held"
  [ ! -d "$LOCK_DIR" ] || held="held by $(lock_holder)"
  printf '%s; ticket %s, %s ahead' "$held" "$ticket" "$ahead"
  [ "$ahead" -eq 0 ] || printf ' (next PR #%s)' "${ahead_pr:-?}"
}

lock_acquire() { # branch
  local common start t last_log=0
  if ! common=$(git rev-parse --git-common-dir 2>/dev/null); then
    echo "pr-merge: run from inside the repository (the merge lock lives in its git dir)" >&2
    exit 1
  fi
  common=$(cd "$common" && pwd)
  LOCK_DIR="$common/pr-merge.lock"
  QUEUE_DIR="$common/pr-merge.queue"
  ticket_take "$1"
  # The wait counts from the ticket.
  start=$(now)
  log "took ticket $ticket in the merge queue $QUEUE_DIR"
  while :; do
    ticket_refresh
    queue_clean
    queue_scan
    if [ "$ahead" -eq 0 ] && mkdir "$LOCK_DIR" 2>/dev/null; then
      lock_held=1
      printf 'pid=%s\npr=%s\nbranch=%s\nstarted=%s\n' "$$" "$pr" "$1" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_DIR/owner"
      ticket_drop
      log "took the merge lock $LOCK_DIR"
      return 0
    fi
    if [ -d "$LOCK_DIR" ] && lock_stale; then
      lock_try_break
      [ -d "$LOCK_DIR" ] || continue
    fi
    t=$(now)
    if [ $((t - start)) -ge "$LOCK_WAIT" ]; then
      echo "pr-merge: gave up after $(( (t - start) / 60 )) min waiting for the merge lock, $(queue_status); nothing merged" >&2
      exit 1
    fi
    if [ $((t - last_log)) -ge 60 ]; then
      log "waiting for the merge lock, $(queue_status); waited $(( (t - start) / 60 )) min"
      last_log=$t
    fi
    nap "$POLL"
  done
}
lock_refresh() {
  if [ "$lock_held" = 1 ]; then
    touch "$LOCK_DIR/owner" 2>/dev/null || true
  fi
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
