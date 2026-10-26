#!/usr/bin/env bash
# triage.sh -- one read-only snapshot of what is wrong in the cluster right
# now, the first step of any debugging (the `homelab-debug` skill starts here).
#
#   scripts/triage.sh                 everything
#   scripts/triage.sh <AlertName>     plus that alert's runbook (Confirm section)
#   scripts/triage.sh <application>   plus that Argo CD application's detail
#
# Sections: the state from scripts/status.sh; Warning events of the last 30
# minutes (Kyverno
# admission denials included, its Audit results not: they are in the policy
# reports); firing alerts; merges to main in the last 6 hours (most
# breakage follows a merge). A section whose source fails says so and the
# others still run.
#
# Exit 0: nothing found. Exit 1: at least one finding, status.sh red
# included. Read-only: status.sh, kubectl get and exec of `amtool alert
# query` only, and `git fetch`.
#
# Environment: KUBECTL (default `kubectl`), GIT (default `git`), STATUS
# (default scripts/status.sh), SINCE_MERGES
# (default `6 hours ago`), EVENTS_MINUTES (default 30), for tests.
set -uo pipefail

KUBECTL=${KUBECTL:-kubectl}
GIT=${GIT:-git}
SINCE_MERGES=${SINCE_MERGES:-6 hours ago}
EVENTS_MINUTES=${EVENTS_MINUTES:-30}
root=$(cd "$(dirname "$0")/.." && pwd)
STATUS=${STATUS:-$root/scripts/status.sh}
target=${1:-}
found=0

section() { # <title> <lines>: print, count findings
  local title=$1 body=$2 n
  n=$(printf '%s' "$body" | grep -c . || true)
  echo "== $title ($n)"
  if [ "$n" -gt 0 ]; then printf '%s\n' "$body"; found=1; fi
}
unavailable() { echo "== $1 (unavailable: $2)"; found=1; }

# The cluster's state: scripts/status.sh (nodes, etcd, Argo CD, pods,
# storage, certificates, backups, the Gateway, the NAS).
echo "== State (scripts/status.sh)"
$STATUS --no-color || found=1

if events=$($KUBECTL get events -A --field-selector type=Warning -o json 2>/dev/null); then
  section "Warning events, last ${EVENTS_MINUTES} min" "$(jq -r --argjson m "$EVENTS_MINUTES" '[.items[]
    | select(((.lastTimestamp // .eventTime // .metadata.creationTimestamp) | sub("\\.[0-9]+"; "") | fromdateiso8601) > (now - $m * 60))
    | select(.reason != "PolicyViolation" or (.message | test("block|denied"; "i")))]
    | group_by(.involvedObject.namespace, .involvedObject.kind, .involvedObject.name, .reason)
    | map(.[0] + {total: (map(.count // 1) | add)}) | sort_by(-.total) | .[0:20][]
    | "\(.involvedObject.namespace // "-")/\(.involvedObject.kind)/\(.involvedObject.name) \(.reason) x\(.total): \(.message | gsub("\n"; " ") | .[0:160])"' <<<"$events")"
else unavailable "Warning events" "kubectl get events"; fi

if alerts=$($KUBECTL -n monitoring exec sts/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager -- \
    amtool alert query --alertmanager.url=http://localhost:9093 -o json 2>/dev/null); then
  section "Firing alerts" "$(jq -r '.[] | select(.labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor")
    | select((.status.silencedBy | length) == 0 and (.status.inhibitedBy | length) == 0)
    | "\(.labels.alertname) severity=\(.labels.severity // "-") action=\(.labels.action // "-") since=\(.startsAt[0:16])"
      + ([.labels | to_entries[] | select(.key | IN("namespace","name","node","app","pod","workload","binary")) | " \(.key)=\(.value)"] | join(""))' <<<"$alerts")"
else unavailable "Firing alerts" "amtool in the Alertmanager pod"; fi

# Informational: merges are context, not findings.
$GIT -C "$root" fetch -q origin main 2>/dev/null || true
merges=$($GIT -C "$root" log origin/main --since="$SINCE_MERGES" --format='%cs %h %s' 2>/dev/null)
echo "== Merged to main since ${SINCE_MERGES} ($(printf '%s' "$merges" | grep -c . || true))"
[ -z "$merges" ] || printf '%s\n' "$merges"

if [ -n "$target" ]; then
  runbook="$root/docs/runbooks/alerts/$target.md"
  if [ -f "$runbook" ]; then
    echo "== Runbook: docs/runbooks/alerts/$target.md, Confirm"
    sed -n '/^## Confirm/,/^## /p' "$runbook" | sed '$d'
  elif app=$($KUBECTL -n argo get application "$target" -o json 2>/dev/null); then
    echo "== Application $target"
    jq -r '"sync=\(.status.sync.status) health=\(.status.health.status) revision=\(.status.sync.revision // (.status.sync.revisions // [] | join(",")))",
      (.status.conditions[]? | "condition \(.type): \(.message | .[0:200])"),
      (.status.resources[]? | select(.status != "Synced" or ((.health.status // "Healthy") != "Healthy"))
        | "resource \(.kind) \(.namespace // "-")/\(.name) sync=\(.status) health=\(.health.status // "-") \(.health.message // "" | .[0:120])")' <<<"$app"
  else
    echo "== $target: no runbook docs/runbooks/alerts/$target.md and no application of that name"
  fi
fi

exit "$found"
