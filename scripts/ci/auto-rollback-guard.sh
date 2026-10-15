#!/bin/bash
# auto-rollback-guard.sh -- is the cluster in an outage right now?
#
# auto-rollback-decide.sh runs this before it reverts anything. A revert is
# meant for one bad merge; during an outage (the switch, the NAS, a node) every
# app degrades at once and whatever merged last takes the blame. So the revert
# is skipped when any of these holds:
#
#   1. MIN_APPS (3) or more different apps reported a failure in the last
#      WINDOW seconds (600). Each report is an auto-rollback.yaml run named
#      `auto-rollback <app>` (`run-name`), so the run list is the history.
#   2. A node is NotReady, or 3. the NAS is unreachable: an alert in
#      OUTAGE_ALERTS (PrometheusRule homelab-outage) is firing. The runner
#      cannot reach the cluster, so it reads the guard topic Alertmanager
#      posts these alerts to at any hour, quiet hours included
#      (`<NTFY_TOPIC>-guard`): the newest message about an alert is titled
#      `CRITICAL: <alert>` while it fires and `Resolved: <alert>` after.
#
# Prints one line, the reason, when there is an outage; nothing otherwise.
# A check that cannot run (no NTFY_TOPIC, an API error) is a warning on stderr
# and counts as no outage: the guard can only ever hold a revert back.
#
# Environment: REPO (owner/name), NOW (epoch seconds, default now), WINDOW,
# MIN_APPS, NTFY_TOPIC, NTFY_URL (default https://ntfy.sh), NTFY_SINCE
# (default 12h, the ntfy.sh message cache), OUTAGE_ALERTS, WORKFLOW
# (default auto-rollback.yaml). Needs gh (actions: read), curl and jq.
set -euo pipefail

: "${REPO:?}"
NOW=${NOW:-$(date +%s)}
WINDOW=${WINDOW:-600}
MIN_APPS=${MIN_APPS:-3}
NTFY_TOPIC=${NTFY_TOPIC:-}
NTFY_URL=${NTFY_URL:-https://ntfy.sh}
NTFY_SINCE=${NTFY_SINCE:-12h}
OUTAGE_ALERTS=${OUTAGE_ALERTS:-HomelabNodeNotReady HomelabNASUnreachable}
WORKFLOW=${WORKFLOW:-auto-rollback.yaml}

warn() { echo "auto-rollback-guard: $*" >&2; }

# 1. Several apps failing at once. GNU date on the runner, BSD date on a Mac.
since=$(date -u -d "@$((NOW - WINDOW))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
  date -u -r "$((NOW - WINDOW))" +%Y-%m-%dT%H:%M:%SZ)
if runs=$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?created=%3E%3D$since&per_page=100" \
  --jq '.workflow_runs[].display_title'); then
  apps=$(sed -n 's/^auto-rollback \([a-z0-9-]*\)$/\1/p' <<<"$runs" | sort -u)
  n=$(grep -c . <<<"$apps" || true)
  if [ "$n" -ge "$MIN_APPS" ]; then
    echo "$n apps failed within $((WINDOW / 60)) minutes: $(tr '\n' ' ' <<<"$apps" | sed 's/ $//')"
    exit 0
  fi
else
  warn "cannot list the $WORKFLOW runs; the several-apps check is skipped"
fi

# 2 and 3. Node or NAS alerts firing.
if [ -z "$NTFY_TOPIC" ]; then
  warn "NTFY_TOPIC is not set; the node and NAS checks are skipped"
  exit 0
fi
if ! msgs=$(curl -fsS -m 15 "$NTFY_URL/$NTFY_TOPIC-guard/json?poll=1&since=$NTFY_SINCE" 2>/dev/null); then
  warn "cannot read the ntfy topic; the node and NAS checks are skipped"
  exit 0
fi
for alert in $OUTAGE_ALERTS; do
  last=$(jq -rs --arg a "$alert" '
      [.[] | select(.event == "message")
           | select((.title // "") | test("^(CRITICAL|Warning|Resolved): " + $a + "( |$)"))]
      | sort_by(.time) | last | .title // ""' <<<"$msgs" 2>/dev/null || true)
  case "$last" in
    CRITICAL:* | Warning:*)
      echo "$alert is firing"
      exit 0
      ;;
  esac
done
exit 0
