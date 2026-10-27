#!/usr/bin/env bash
# alert-triage.sh -- one pass of the alert-triage CronJob (spec alert-triage):
# a triage.sh snapshot for every new page, kept in the cluster, announced on
# ntfy with counts only.
#
#   1. Alert groups from Alertmanager (active, not silenced, not inhibited)
#      with an `action="human"` alert are pages.
#   2. A page whose group key is not in ConfigMap alert-triage-state (entries
#      expire after STATE_TTL, 6 h) gets one run: `triage.sh <alertname>`,
#      stored in ConfigMap alert-triage-<UTC time>-<alertname, lowercased>,
#      and a low-priority ntfy message with the section counts and the command
#      that reads it. Nothing from the snapshot body goes to ntfy.
#   3. Snapshots older than SNAP_TTL (7 days) are deleted; the state is
#      written back.
#
# Alert labels are untrusted (a Tetragon alert carries a binary path an
# attacker picks): only the alert name is used, and only if it matches
# ^[A-Za-z0-9]+$; anything else is recorded as `alertname rejected` and not
# run.
#
# Exit 0: every run done. Exit 1: a run, the Alertmanager read or a write
# failed (AlertTriageFailing counts failed Jobs).
#
# Environment: AM_URL (default the in-cluster Alertmanager), NTFY_URL (the
# topic URL; unset: no message), NAMESPACE (default monitoring), KUBECTL,
# CURL, TRIAGE (default scripts/triage.sh), NOW (epoch seconds), STATE_TTL,
# SNAP_TTL, for tests.
set -uo pipefail

AM_URL=${AM_URL:-http://alertmanager-operated.monitoring.svc:9093}
NAMESPACE=${NAMESPACE:-monitoring}
KUBECTL=${KUBECTL:-kubectl}
CURL=${CURL:-curl}
root=$(cd "$(dirname "$0")/.." && pwd)
TRIAGE=${TRIAGE:-$root/scripts/triage.sh}
NOW=${NOW:-$(date -u +%s)}
STATE_TTL=${STATE_TTL:-21600}
SNAP_TTL=${SNAP_TTL:-604800}
STATE_CM=alert-triage-state
LABEL=app=alert-triage
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log() { echo "alert-triage: $*"; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
k() { $KUBECTL -n "$NAMESPACE" --request-timeout=20s "$@"; }

if ! $CURL -fsS -m 20 "$AM_URL/api/v2/alerts/groups?active=true&silenced=false&inhibited=false" > "$tmp/groups.json" 2>/dev/null \
    || ! jq -e 'type == "array"' "$tmp/groups.json" >/dev/null 2>&1; then
  log "cannot read the alert groups from $AM_URL"
  exit 1
fi

# One line per page: <group key hash> <alert name>.
jq -r '.[] | select(any(.alerts[]; .labels.action == "human"))
  | [(.receiver.name + ({} + .labels | tojson)), ([.alerts[] | select(.labels.action == "human")][0].labels.alertname // "")]
  | @tsv' "$tmp/groups.json" | while IFS=$'\t' read -r key name; do
  printf '%s\t%s\n' "$(printf '%s' "$key" | sha | cut -c1-16)" "$name"
done > "$tmp/pages.tsv"

# State: {"<key>": <first-seen epoch>}, expired entries dropped.
state=$(k get configmap "$STATE_CM" -o json 2>/dev/null | jq -c '.data.state // "{}" | fromjson' 2>/dev/null) || state='{}'
[ -n "$state" ] || state='{}'
state=$(jq -c --argjson now "$NOW" --argjson ttl "$STATE_TTL" 'with_entries(select(.value > $now - $ttl))' <<<"$state")

stamp=$(date -u -r "$NOW" +%Y%m%dt%H%M 2>/dev/null || date -u -d "@$NOW" +%Y%m%dt%H%M)

while IFS=$'\t' read -r key name; do
  [ -n "$key" ] || continue
  if jq -e --arg k "$key" 'has($k)' <<<"$state" >/dev/null; then continue; fi
  state=$(jq -c --arg k "$key" --argjson now "$NOW" '. + {($k): $now}' <<<"$state")
  if ! [[ $name =~ ^[A-Za-z0-9]+$ ]]; then
    log "group $key: alertname rejected"
    continue
  fi
  cm="alert-triage-$stamp-$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  "$TRIAGE" "$name" > "$tmp/snapshot" 2>&1; rc=$?
  # triage.sh: 0 nothing found, 1 findings; anything else is a failed run.
  if [ "$rc" -gt 1 ]; then
    log "group $key: triage.sh $name exited $rc"
    failed=1
    summary="triage.sh failed (exit $rc)"
  else
    summary=$(sed -n 's/^== \(.*\) (\([0-9][0-9]*\))$/\1: \2/p' "$tmp/snapshot" | paste -sd ';' - | sed 's/;/; /g')
  fi
  if k create configmap "$cm" --from-file=snapshot="$tmp/snapshot" >/dev/null 2>&1 \
      && k label configmap "$cm" "$LABEL" >/dev/null 2>&1; then
    log "group $key: $name stored in configmap/$cm"
  else
    log "group $key: cannot store configmap/$cm"
    failed=1
  fi
  if [ -n "${NTFY_URL:-}" ]; then
    body="$summary
kubectl -n $NAMESPACE get cm $cm -o jsonpath='{.data.snapshot}'"
    $CURL -fsS -m 20 -H "Title: triage: $name" -H "Priority: low" -H "Tags: mag" \
      --data-binary "$body" "$NTFY_URL" >/dev/null 2>&1 || { log "ntfy post failed"; failed=1; }
  fi
done < "$tmp/pages.tsv"

# Snapshots past SNAP_TTL.
if old=$(k get configmap -l "$LABEL" -o json 2>/dev/null); then
  jq -r --argjson now "$NOW" --argjson ttl "$SNAP_TTL" --arg state "$STATE_CM" '.items[]
    | select(.metadata.name != $state)
    | select((.metadata.creationTimestamp | fromdateiso8601) < $now - $ttl) | .metadata.name' <<<"$old" \
  | while read -r cm; do
    k delete configmap "$cm" >/dev/null 2>&1 && log "expired configmap/$cm"
  done
else
  log "cannot list the snapshots"; failed=1
fi

if ! k create configmap "$STATE_CM" --from-literal=state="$state" --dry-run=client -o yaml 2>/dev/null \
    | $KUBECTL label --local -f - "$LABEL" -o yaml 2>/dev/null \
    | k apply -f - >/dev/null 2>&1; then
  log "cannot write configmap/$STATE_CM"
  failed=1
fi

exit "$failed"
