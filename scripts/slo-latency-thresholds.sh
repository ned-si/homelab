#!/bin/bash
# slo-latency-thresholds.sh -- the latency threshold of each SLO app
# (docs/sre.md, Latency): the smallest step of the ladder 0.25 0.5 1 2 5 s
# that is at least twice the app's p95 `probe_duration_seconds` (job
# blackbox-public) over the last <days> days. Read-only: it queries Prometheus
# through a port-forward and changes nothing.
#
#   scripts/slo-latency-thresholds.sh [days]     # default 14
#
# Output, one line per app of group homelab.slo.apps in
# platform/kube-prometheus-stack/routes/slo.yaml:
#
#   <app> p95=<s> threshold=<s> slow=<share of successful probes slower than the threshold>
#
# then `data=<days>d`, the age of the oldest probe sample in the window (less
# than <days> when Prometheus holds less). The thresholds go into group
# homelab.slo.latency-thresholds of slo.yaml as static values.
#
# Requires kubectl (on the cluster), curl, jq and yq v4.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
days=${1:-14}
case "$days" in '' | *[!0-9]*) echo "usage: $0 [days]" >&2; exit 64 ;; esac
port=${PROM_PORT:-19090}
for t in kubectl curl jq yq; do
  command -v "$t" >/dev/null 2>&1 || { echo "slo-latency-thresholds: $t not found" >&2; exit 1; }
done

apps=$(yq -r '.spec.groups[] | select(.name == "homelab.slo.apps") | .rules[].labels.app' \
  platform/kube-prometheus-stack/routes/slo.yaml)
[ -n "$apps" ] || { echo "slo-latency-thresholds: no SLO app in slo.yaml" >&2; exit 1; }

kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus "$port:9090" >/dev/null 2>&1 &
pf=$!
# shellcheck disable=SC2329 # invoked by the trap
cleanup() { # keep the script's exit status, not the killed port-forward's
  local rc=$?
  kill "$pf" 2>/dev/null
  wait "$pf" 2>/dev/null
  exit "$rc"
}
trap cleanup EXIT
ready=0
for _ in $(seq 1 50); do
  curl -fsS -m 1 "http://127.0.0.1:$port/-/ready" >/dev/null 2>&1 && { ready=1; break; }
  sleep 0.2
done
[ "$ready" = 1 ] || { echo "slo-latency-thresholds: Prometheus port-forward not ready" >&2; exit 1; }

q() { # PromQL -> the value of the only result, or empty
  curl -fsS -m 120 "http://127.0.0.1:$port/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[0].value[1] // empty'
}

for app in $apps; do
  sel="job=\"blackbox-public\", app=\"$app\""
  p95=$(q "max(quantile_over_time(0.95, probe_duration_seconds{$sel}[${days}d]))")
  [ -n "$p95" ] || { echo "$app p95=none threshold=none slow=none"; continue; }
  threshold=$(awk -v p="$p95" 'BEGIN { split("0.25 0.5 1 2 5", l, " "); t = "none";
    for (i = 1; i <= 5; i++) if (l[i] >= 2 * p) { t = l[i]; break } print t }')
  slow=none
  if [ "$threshold" != none ]; then
    slow=$(q "sum(count_over_time((probe_duration_seconds{$sel} > $threshold and on (instance, app) probe_success{$sel} == 1)[${days}d:1m]))
      / sum(count_over_time(probe_duration_seconds{$sel}[${days}d:1m]))")
    slow=$(awk -v s="${slow:-0}" 'BEGIN { printf "%.4f", s }')
  fi
  printf '%s p95=%.3f threshold=%s slow=%s\n' "$app" "$p95" "$threshold" "$slow"
done
oldest=$(q "time() - min(min_over_time(timestamp(probe_success{job=\"blackbox-public\"})[${days}d:1h]))")
awk -v s="${oldest:-0}" 'BEGIN { printf "data=%.1fd\n", s / 86400 }'
