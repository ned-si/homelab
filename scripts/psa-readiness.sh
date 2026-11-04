#!/usr/bin/env bash
# psa-readiness.sh <namespace>
#
# Is the namespace ready for `pod-security.kubernetes.io/enforce=restricted`?
# The gate of the pod-security-restricted spec (.kiro/specs/), read-only:
# every kubectl call is a `get` or a `--dry-run=server`.
#
#   G1  `kubectl label --dry-run=server` of enforce=restricted: the API server
#       evaluates every existing Pod and warns per failing Pod. Pass: no
#       warning. A no-op once the namespace enforces restricted.
#   G2  The namespace's PolicyReports: no `fail` of a Pod Security Standards
#       policy (policies/kyverno/upstream/pod-security-vpol/*/*, baseline and
#       restricted) on a Pod, Deployment, StatefulSet, DaemonSet, Job, CronJob,
#       or a ReplicaSet with spec.replicas above 0; and KyvernoReportsStale
#       not firing in Alertmanager.
#   G3  Each controller's pod template (Deployments, StatefulSets with their
#       claim templates, DaemonSets, CronJobs, Jobs not owned by a CronJob,
#       ReplicaSets not owned by a Deployment, scaled to 0 included) sent as
#       a Pod with `kubectl create --dry-run=server`. Pass: no PodSecurity
#       warning or error. Any other dry-run error reads as a failure. Needs
#       the namespace's `warn` (or `enforce`) label at restricted.
#
# Output: one line per finding, then READY or NOT READY.
# Exit 0 READY, 1 NOT READY, 64 usage.
#
# Environment: KUBECONFIG (needs dry-run create on pods and patch on
# namespaces, so the admin kubeconfig), KUBECTL (default `kubectl`, for tests).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL=${KUBECTL:-kubectl}
AM_ALERTS='/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts?active=true'
LEVEL_LABEL='pod-security.kubernetes.io'

usage() {
  echo "usage: $0 <namespace>" >&2
  exit 64
}

[ "$#" -eq 1 ] || usage
ns=$1
[[ "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || usage

# kc: kubectl restricted to reads and server dry runs.
kc() {
  case "$1" in
    get) ;;
    label|create)
      case " $* " in
        *" --dry-run=server "*) ;;
        *) echo "psa-readiness: refusing kubectl $1 without --dry-run=server" >&2; exit 70 ;;
      esac ;;
    *) echo "psa-readiness: refusing kubectl $1" >&2; exit 70 ;;
  esac
  "$KUBECTL" --request-timeout=20s "$@"
}

fails=0
fail() { fails=$((fails + 1)); printf '%s FAIL %s\n' "$1" "$2"; }
pass() { printf '%s ok   %s\n' "$1" "$2"; }

echo "psa-readiness $ns $(date -u +%Y-%m-%dT%H:%M:%SZ)"

nsjson=$(kc get namespace "$ns" -o json) || { echo "NOT READY: namespace $ns not readable"; exit 1; }
enforce=$(printf '%s' "$nsjson" | jq -r --arg l "$LEVEL_LABEL/enforce" '.metadata.labels[$l] // "unset"')
warn=$(printf '%s' "$nsjson" | jq -r --arg l "$LEVEL_LABEL/warn" '.metadata.labels[$l] // "unset"')

# G1
if out=$(kc label --dry-run=server --overwrite namespace "$ns" "$LEVEL_LABEL/enforce=restricted" 2>&1); then
  warnings=$(printf '%s\n' "$out" | grep '^Warning:' || true)
  if [ -n "$warnings" ]; then
    while IFS= read -r line; do fail G1 "${line#Warning: }"; done <<< "$warnings"
  elif [ "$enforce" = restricted ]; then
    pass G1 "already enforces restricted (existing Pods are not re-evaluated)"
  else
    pass G1 "label dry run: no warning"
  fi
else
  fail G1 "label dry run failed: $(printf '%s' "$out" | tr '\n' ' ')"
fi

# G2
pols=$(for d in "$REPO"/policies/kyverno/upstream/pod-security-vpol/*/*/; do
  [ -d "$d" ] && basename "$d"
done | jq -R . | jq -sc .)
if [ "$pols" = "[]" ]; then
  fail G2 "no Pod Security Standards policies under policies/kyverno/upstream/pod-security-vpol"
elif ! rs=$(kc get replicasets -n "$ns" -o json | jq -c '[.items[] | {key: .metadata.name, value: (.spec.replicas // 1)}] | from_entries'); then
  fail G2 "replicasets not readable"
elif ! polr=$(kc get policyreports.wgpolicyk8s.io -n "$ns" -o json); then
  fail G2 "policyreports not readable"
else
  found=$(printf '%s' "$polr" | jq -r --argjson pols "$pols" --argjson rs "$rs" '
    .items[]
    | .scope as $s
    | select($s.kind | IN("Pod", "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "ReplicaSet"))
    | select($s.kind != "ReplicaSet" or (($rs[$s.name] // 0) > 0))
    | [.results[]? | select(.result == "fail") | .policy | select(IN($pols[]))] | unique
    | select(length > 0)
    | "\($s.kind)/\($s.name): \(join(", "))"')
  if [ -n "$found" ]; then
    while IFS= read -r line; do fail G2 "$line"; done <<< "$found"
  else
    pass G2 "reports: no fail of the $(printf '%s' "$pols" | jq length) Pod Security Standards policies"
  fi
fi
if ! alerts=$(kc get --raw "$AM_ALERTS"); then
  fail G2 "Alertmanager not readable, report freshness unknown"
elif printf '%s' "$alerts" | jq -e 'any(.[]; .labels.alertname == "KyvernoReportsStale")' > /dev/null; then
  fail G2 "KyvernoReportsStale is firing: the reports may be stale"
else
  pass G2 "KyvernoReportsStale not firing"
fi

# G3
if [ "$enforce" != restricted ] && [ "$warn" != restricted ]; then
  fail G3 "warn label is $warn: a dry run cannot see restricted violations"
elif ! ctrl=$(kc get deployments,statefulsets,daemonsets,replicasets,jobs,cronjobs -n "$ns" -o json); then
  fail G3 "controllers not readable"
else
  pods=$(printf '%s' "$ctrl" | jq -rc --arg ns "$ns" '
    def owned(k): (.metadata.ownerReferences // []) | any(.kind == k);
    .items[]
    | select(((.kind == "ReplicaSet" and owned("Deployment")) or (.kind == "Job" and owned("CronJob"))) | not)
    | .metadata.name as $n
    | (if .kind == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end) as $spec
    | [(.spec.volumeClaimTemplates // [])[]
       | {name: .metadata.name, persistentVolumeClaim: {claimName: "\(.metadata.name)-\($n)-0"}}] as $claims
    | "\(.kind)/\($n)",
      {apiVersion: "v1", kind: "Pod",
       metadata: {generateName: "psa-readiness-", namespace: $ns},
       spec: ($spec + {volumes: (($spec.volumes // []) + $claims)})}')
  n=0; before=$fails
  while IFS= read -r id && IFS= read -r pod; do
    n=$((n + 1))
    if out=$(printf '%s' "$pod" | kc create --dry-run=server -f - -o name 2>&1); then
      psw=$(printf '%s\n' "$out" | grep 'PodSecurity' || true)
      [ -z "$psw" ] || fail G3 "$id: ${psw#Warning: }"
    else
      fail G3 "$id: dry run failed: $(printf '%s' "$out" | tr '\n' ' ')"
    fi
  done <<< "$pods"
  [ "$fails" -gt "$before" ] || pass G3 "$n pod templates: no PodSecurity warning"
fi

if [ "$fails" -eq 0 ]; then
  echo READY
  exit 0
fi
echo "NOT READY ($fails)"
exit 1
