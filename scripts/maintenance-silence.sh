#!/bin/bash
# maintenance-silence.sh <target> <duration> <reason>
# maintenance-silence.sh --expire <silence-id>
#
# Silence the alerts of a planned disruptive change before it starts, for a
# fixed time, through the Alertmanager API (amtool inside the Alertmanager
# pod, so nothing is needed on the Mac but kubectl). Prints the silence ID;
# `--expire <id>` ends it early when the work is done.
#
#   target    a namespace (`keycloak`): every alert with that `namespace`
#             label, which includes the app's SLO burns and Argo CD alerts;
#             `node/<node>` (`node/homelab-w-1`): every alert with that
#             `node` label; `cluster`: every alert but `Watchdog`, which is
#             never silenced (the heartbeat must keep running).
#   duration  1m to 12h, amtool format (`30m`, `2h`, `1h30m`).
#   reason    the silence comment: what is being done, e.g. a PR number.
#
# Environment: KUBECONFIG (needs `pods/exec` in `monitoring`), SILENCE_AUTHOR
# (default $USER). Exit 0 done, 1 Alertmanager error, 64 usage.
set -euo pipefail

NS=monitoring
POD=alertmanager-kube-prometheus-stack-alertmanager-0
MAX_MINUTES=720

usage() {
  sed -n '2,3p' "$0" | sed 's/^# //' >&2
  exit 64
}

amtool() { # amtool args... inside the Alertmanager pod
  kubectl --request-timeout=20s -n "$NS" exec "$POD" -c alertmanager -- \
    amtool --alertmanager.url=http://localhost:9093 "$@"
}

if [ "${1:-}" = "--expire" ]; then
  [ "$#" -eq 2 ] && [[ "$2" =~ ^[0-9a-f-]{36}$ ]] || usage
  amtool silence expire "$2" || { echo "maintenance-silence: expire failed" >&2; exit 1; }
  echo "expired $2"
  exit 0
fi

[ "$#" -eq 3 ] || usage
target=$1 duration=$2 reason=$3

case "$target" in
  cluster) matchers=('alertname!=Watchdog') ;;
  node/*)
    node=${target#node/}
    [[ "$node" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || usage
    matchers=("node=$node") ;;
  *)
    [[ "$target" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || usage
    matchers=("namespace=$target") ;;
esac

if [[ "$duration" =~ ^(([0-9]+)h)?(([0-9]+)m)?$ ]] && [ -n "$duration" ]; then
  minutes=$(( 10#${BASH_REMATCH[2]:-0} * 60 + 10#${BASH_REMATCH[4]:-0} ))
else
  usage
fi
if [ "$minutes" -lt 1 ] || [ "$minutes" -gt "$MAX_MINUTES" ]; then
  echo "maintenance-silence: duration must be 1m to 12h" >&2
  exit 64
fi
[ -n "${reason// /}" ] || usage

if ! id=$(amtool silence add --author="${SILENCE_AUTHOR:-${USER:-maintenance}}" \
      --comment="maintenance: $reason" --duration="$duration" "${matchers[@]}"); then
  echo "maintenance-silence: Alertmanager refused the silence" >&2
  exit 1
fi
echo "silenced ${matchers[*]} for $duration: $id"
echo "end early: $0 --expire $id"
