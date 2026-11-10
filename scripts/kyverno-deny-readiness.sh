#!/usr/bin/env bash
# kyverno-deny-readiness.sh <policy>
#
# Can the Kyverno ValidatingPolicy <policy> move from Audit to Deny? The gate
# of the per-app-hardening spec (.kiro/specs/, tasks 37 and 38), read-only:
# every kubectl call is a `get`.
#
#   K1  The PolicyReports of every namespace not in EXCLUDED_NAMESPACES
#       (parsed from scripts/ci/kyverno.sh): no `fail` of <policy> on a Pod,
#       Deployment, StatefulSet, DaemonSet, Job, CronJob, or a ReplicaSet
#       with spec.replicas above 0. PolicyExceptions already turn their
#       objects' results into `skip`.
#   K2  KyvernoReportsStale not firing in Alertmanager (through the API
#       server's service proxy), and the newest results[].timestamp.seconds
#       across the PolicyReports under 2 hours old (the background scan runs
#       every hour).
#
# Output: `K1 ok` or one `K1 FAIL` line per failing object with its message,
# `K2 ok` or the reason, then READY or NOT READY. An unreachable API server,
# a report that does not parse or an unknown policy print `NOT READY: <why>`.
# Exit 0 READY, 1 NOT READY, 64 usage.
#
# Environment: KUBECONFIG, KUBECTL (default `kubectl`, for tests).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL=${KUBECTL:-kubectl}
AM_ALERTS='/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts?active=true'
MAX_AGE=7200

usage() {
  echo "usage: $0 <policy>" >&2
  exit 64
}

[ "$#" -eq 1 ] || usage
policy=$1
[[ "$policy" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || usage

# kc: kubectl restricted to reads.
kc() {
  [ "$1" = get ] || { echo "kyverno-deny-readiness: refusing kubectl $1" >&2; exit 70; }
  "$KUBECTL" --request-timeout=10s "$@"
}

errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
err() { tr '\n' ' ' < "$errf"; }

not_ready() {
  printf 'NOT READY: %s\n' "$(printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//')"
  exit 1
}

excluded=$(sed -n 's/^EXCLUDED_NAMESPACES="\([^"]*\)"$/\1/p' "$REPO/scripts/ci/kyverno.sh")
[ -n "$excluded" ] || not_ready "EXCLUDED_NAMESPACES not found in scripts/ci/kyverno.sh"
# shellcheck disable=SC2086 # one argument per namespace
excluded=$(printf '%s\n' $excluded | jq -R . | jq -sc .)

if ! kc get validatingpolicies.policies.kyverno.io "$policy" -o name > /dev/null 2> "$errf"; then
  case "$(err)" in
    *NotFound*) not_ready "no ValidatingPolicy $policy" ;;
    *) not_ready "ValidatingPolicy $policy not readable: $(err)" ;;
  esac
fi

polr=$(kc get policyreports.wgpolicyk8s.io -A -o json 2> "$errf") || not_ready "policyreports not readable: $(err)"
rs=$(kc get replicasets -A -o json 2> "$errf") || not_ready "replicasets not readable: $(err)"
rs=$(printf '%s' "$rs" | jq -c '[.items[] | {key: "\(.metadata.namespace)/\(.metadata.name)", value: (.spec.replicas // 1)}] | from_entries' 2> "$errf") ||
  not_ready "replicasets not parseable: $(err)"

# K1
found=$(printf '%s' "$polr" | jq -r --arg p "$policy" --argjson excl "$excluded" --argjson rs "$rs" '
  .items[]
  | .metadata.namespace as $ns
  | .scope as $s
  | select(($ns | IN($excl[])) | not)
  | select($s.kind | IN("Pod", "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "ReplicaSet"))
  | select($s.kind != "ReplicaSet" or (($rs["\($ns)/\($s.name)"] // 0) > 0))
  | [.results[]? | select(.policy == $p and .result == "fail") | .message // "fail"] | unique
  | select(length > 0)
  | "\($ns)/\($s.kind)/\($s.name): \(join("; "))"' 2> "$errf") || not_ready "policyreports not parseable: $(err)"
newest=$(printf '%s' "$polr" | jq -r '[.items[].results[]?.timestamp.seconds // empty] | max // 0 | floor' 2> "$errf") ||
  not_ready "policyreports not parseable: $(err)"

fails=0
if [ -n "$found" ]; then
  while IFS= read -r line; do
    fails=$((fails + 1))
    printf 'K1 FAIL %s\n' "$line"
  done <<< "$found"
else
  echo "K1 ok"
fi

# K2
reasons=()
if ! alerts=$(kc get --raw "$AM_ALERTS" 2> "$errf"); then
  reasons+=("Alertmanager not readable: $(err)")
elif ! firing=$(printf '%s' "$alerts" | jq -r 'any(.[]; .labels.alertname == "KyvernoReportsStale")' 2> "$errf"); then
  reasons+=("Alertmanager answer not parseable: $(err)")
elif [ "$firing" = true ]; then
  reasons+=("KyvernoReportsStale is firing")
fi
now=$(date +%s)
if [ "$newest" = 0 ]; then
  reasons+=("no PolicyReport result has a timestamp")
elif [ $((now - newest)) -ge "$MAX_AGE" ]; then
  reasons+=("newest PolicyReport result is $(((now - newest) / 60)) minutes old (limit $((MAX_AGE / 60)))")
fi
if [ "${#reasons[@]}" -eq 0 ]; then
  echo "K2 ok"
else
  for r in "${reasons[@]}"; do
    fails=$((fails + 1))
    printf 'K2 FAIL %s\n' "$r"
  done
fi

if [ "$fails" -eq 0 ]; then
  echo READY
  exit 0
fi
echo "NOT READY"
exit 1
