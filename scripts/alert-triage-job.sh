#!/usr/bin/env bash
# alert-triage-job.sh -- the snapshot Job of the alert-triage receiver (spec
# alert-triage): scripts/triage.sh <alertname>, every line logged as JSON for
# the store, and a low-priority ntfy message with the counts and the store
# link only. Nothing from the snapshot body goes to ntfy.
#
# The receiver checked the alert name; it is checked again here, as this
# script is what runs with the snapshot ServiceAccount.
#
# Exit 0: snapshot taken (findings or not). Exit 1: triage.sh failed, the
# name was rejected or the ntfy post failed (AlertTriageFailing counts
# failed Jobs).
#
# Environment: ALERTNAME, INCIDENT_ID (from the receiver), FIX (the fix's
# alert name, or `none`), NTFY_URL (topic URL; unset: no message), STORE_URL
# (`{id}` is replaced by the incident id; unset: the id alone), TRIAGE
# (default scripts/triage.sh), CURL, for tests.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
TRIAGE=${TRIAGE:-$root/scripts/triage.sh}
CURL=${CURL:-curl}
ALERTNAME=${ALERTNAME:-}
INCIDENT_ID=${INCIDENT_ID:-}
FIX=${FIX:-none}

log() { # <event> <msg>
  jq -cn --arg e "$1" --arg m "$2" --arg id "$INCIDENT_ID" --arg a "$ALERTNAME" \
    '{time: (now | todate), event: $e, "incident.id": $id, alertname: $a, msg: $m}'
}

if ! [[ $ALERTNAME =~ ^[A-Za-z0-9]+$ ]] || ! [[ $INCIDENT_ID =~ ^[0-9a-f]{16}$ ]]; then
  ALERTNAME="" log failed "alertname rejected"
  exit 1
fi

# In the Job: status.sh skips the checks that need the operator's machine.
export IN_CLUSTER=1
out=$("$TRIAGE" "$ALERTNAME" 2>&1); rc=$?
while IFS= read -r line; do log snapshot "$line"; done <<<"$out"

# summary <triage output>: the counts line of the message; `?` for a
# section that is missing or unavailable.
summary() {
  local p='?' w='?' a='?' m='?' line n
  while IFS= read -r line; do
    n=${line##*(}; n=${n%)}
    [[ $n =~ ^[0-9]+$ ]] || n='?'
    case "$line" in
      "== Warning events"*) w=$n ;;
      "== Firing alerts"*) a=$n ;;
      "== Merged to main"*) m=$n ;;
      *"no problems") p=0 ;;
      *" problem(s)") n=${line% problem(s)}; n=${n##* }; [[ $n =~ ^[0-9]+$ ]] && p=$n ;;
    esac
  done
  echo "Snapshot: $p problems, $w warning events, $a firing alerts, $m merges (6 h)"
}

failed=0
# triage.sh: 0 nothing found, 1 findings; anything else is a failed run.
if [ "$rc" -gt 1 ]; then
  log failed "triage.sh exited $rc"
  failed=1
  counts="Snapshot: failed (triage.sh exit $rc)"
else
  counts=$(summary <<<"$out")
fi
if [ "$FIX" = none ]; then fixline="Fix: none for this alert"; else fixline="Fix: started, see the store"; fi
if [ -n "${STORE_URL:-}" ]; then link=${STORE_URL//\{id\}/$INCIDENT_ID}; else link="incident.id=$INCIDENT_ID"; fi
body="$counts
$fixline
$link"

if [ -n "${NTFY_URL:-}" ]; then
  if $CURL -fsS -m 20 -H "Title: triage: $ALERTNAME" -H "Priority: low" -H "Tags: mag" \
      --data-binary "$body" "$NTFY_URL" >/dev/null 2>&1; then
    log snapshot "ntfy sent"
  else
    log failed "ntfy post failed"
    failed=1
  fi
fi
exit "$failed"
