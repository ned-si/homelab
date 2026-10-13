#!/bin/bash
# status.sh -- a read-only, one-screen view of the cluster, for when Grafana
# is not at hand.
#
# usage: scripts/status.sh [--json] [--no-color]
#
# Shows: nodes (Ready, kubelet, kernel, runtime), etcd health and the API VIP,
# Argo CD Applications not Synced/Healthy, pods not Running/Completed and the
# most restarted, PVCs, CNPG clusters, certificate expiry, the Gateway, its
# HTTPRoutes and every LoadBalancer address, the latest run of each backup
# CronJob, NAS reachability, the WAN address against --default-targets in
# infrastructure/external-dns/values.yaml, Immich asset counts, and Secrets by
# namespace (names and ages only; values are never read into this script).
#
# Read-only: kubectl get / exec of read-only commands (etcdctl endpoint
# health, psql with default_transaction_read_only=on), nc -z, two HTTPS calls
# for the WAN address. Every call is bounded (kubectl --request-timeout,
# nc -G, curl -m).
#
# Exit 0 when nothing is red, 1 when something is (a kubectl read that fails
# counts), 64 on a usage error.
# --json prints one JSON document instead of the text view.
#
# Requires bash 3.2+, kubectl, jq, nc, curl (macOS flags: nc -G).
# shellcheck disable=SC2016 # single-quoted strings are jq programs
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

JSON=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --no-color) export NO_COLOR=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--json] [--no-color]" >&2; exit 64 ;;
  esac
done

# shellcheck source=scripts/lib/cluster.sh
. "$ROOT/scripts/lib/cluster.sh"

API_VIP=${STATUS_API_VIP:-192.168.1.11}
NAS_HOST=${STATUS_NAS_HOST:-192.168.1.228}
NAS_PORTS=${STATUS_NAS_PORTS:-"3260 2049"}
CERT_WARN_DAYS=${STATUS_CERT_WARN_DAYS:-21}
BACKUP_MAX_H=${STATUS_BACKUP_MAX_H:-26}
NOW=${STATUS_NOW:-$(date -u +%s)}

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

T=$(mktemp -d "${TMPDIR:-/tmp}/status.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$T"' EXIT

# A failed read is a problem, not an empty list: it is recorded in
# $T/errors.txt and reported (an unreachable API must not look healthy).
: > "$T/errors.txt"
read_failed() { # <what> <stderr file>
  printf '%s\n' "kubectl get $1 failed: $(head -n 1 "$2" 2>/dev/null | cut -c1-160)" >> "$T/errors.txt"
}

# getj <file> <kubectl args...>: JSON list into $T/<file>; an empty list and
# an error line when the read fails.
getj() {
  local f=$1; shift
  if ! k get "$@" -o json > "$T/$f" 2> "$T/$f.err" || ! jq -e '.items' "$T/$f" >/dev/null 2>&1; then
    read_failed "$*" "$T/$f.err"
    echo '{"items":[]}' > "$T/$f"
  fi
}

tcp_open() { nc -z -G 3 "$1" "$2" >/dev/null 2>&1; }

# --- collect ------------------------------------------------------------------
getj nodes.raw nodes
jq -c '[.items[] | {name: .metadata.name,
    ready: ([.status.conditions[]? | select(.type == "Ready") | .status][0] == "True"),
    unschedulable: (.spec.unschedulable // false),
    kubelet: .status.nodeInfo.kubeletVersion, kernel: .status.nodeInfo.kernelVersion,
    os: .status.nodeInfo.osImage, runtime: .status.nodeInfo.containerRuntimeVersion,
    ip: ([.status.addresses[]? | select(.type == "InternalIP") | .address][0])}]' "$T/nodes.raw" > "$T/nodes.json"

etcd=$(etcd_health_json) || etcd=null
vip=false; tcp_open "$API_VIP" 6443 && vip=true
jq -n --argjson e "$etcd" --arg ip "$API_VIP" --argjson vip "$vip" \
  '{members: (if $e == null then null else ($e | length) end),
    healthy: (if $e == null then null else ([$e[] | select(.health == true)] | length) end),
    vip: $ip, vip_reachable: $vip}' > "$T/etcd.json"

getj argo.raw applications.argoproj.io -n argo
jq -c '{total: (.items | length),
    bad: [.items[] | {name: .metadata.name, sync: (.status.sync.status // "Unknown"), health: (.status.health.status // "Unknown")}
          | select(.sync != "Synced" or .health != "Healthy")]}' "$T/argo.raw" > "$T/argo.json"

getj pods.raw pods -A
jq -c '[.items[] | {ns: .metadata.namespace, name: .metadata.name, phase: (.status.phase // "Unknown"),
      restarts: ([(.status.containerStatuses // [])[].restartCount] | add // 0),
      waiting: ([(.status.initContainerStatuses // [])[], (.status.containerStatuses // [])[] | .state.waiting.reason // empty] | unique),
      unready: ([(.status.containerStatuses // [])[] | select(.ready | not)] | length)}]
    | {total: length,
       bad: [.[] | select((.phase != "Running" and .phase != "Succeeded") or (.waiting | length) > 0 or (.phase == "Running" and .unready > 0))
             | {ns, name, phase, reason: ((.waiting | join(",")) // ""), restarts}],
       restarts: ([.[] | select(.restarts > 0) | {ns, name, restarts}] | sort_by(-.restarts) | .[0:3])}' "$T/pods.raw" > "$T/pods.json"

getj pvc.raw pvc -A
jq -c '{total: (.items | length), bound: ([.items[] | select(.status.phase == "Bound")] | length),
    not_bound: [.items[] | select(.status.phase != "Bound") | {ns: .metadata.namespace, name: .metadata.name, phase: (.status.phase // "Unknown")}]}' \
  "$T/pvc.raw" > "$T/pvc.json"

getj cnpg.raw clusters.postgresql.cnpg.io -A
jq -c '[.items[] | {ns: .metadata.namespace, name: .metadata.name, phase: (.status.phase // "Unknown"),
    ready: (.status.readyInstances // 0), instances: (.spec.instances // 0)}]' "$T/cnpg.raw" > "$T/cnpg.json"

getj certs.raw certificates.cert-manager.io -A
jq -c --argjson now "$NOW" '[.items[] | {ns: .metadata.namespace, name: .metadata.name,
    ready: ([.status.conditions[]? | select(.type == "Ready") | .status][0] == "True"),
    not_after: (.status.notAfter // null)}
    | . + {days: (if .not_after then (((.not_after | fromdateiso8601) - $now) / 86400 | floor) else null end)}]
    | sort_by(.days)' "$T/certs.raw" > "$T/certs.json"

getj gw.raw gateways.gateway.networking.k8s.io -A
getj routes.raw httproutes.gateway.networking.k8s.io -A
getj svc.raw svc -A
jq -n -c --slurpfile g "$T/gw.raw" --slurpfile r "$T/routes.raw" --slurpfile s "$T/svc.raw" '{
    gateways: [$g[0].items[] | {ns: .metadata.namespace, name: .metadata.name,
      address: ([.status.addresses[]?.value] | join(",")),
      programmed: ([.status.conditions[]? | select(.type == "Programmed") | .status][0] == "True")}],
    routes: [$r[0].items[] | {ns: .metadata.namespace, name: .metadata.name, hosts: (.spec.hostnames // []),
      accepted: ([.status.parents[]?.conditions[]? | select(.type == "Accepted") | .status] | length > 0 and all(. == "True"))}],
    loadbalancers: [$s[0].items[] | select(.spec.type == "LoadBalancer")
      | {svc: "\(.metadata.namespace)/\(.metadata.name)", ips: [.status.loadBalancer.ingress[]?.ip // empty]}]}' > "$T/gateway.json"

getj cj.raw cronjobs -A
jq -c --argjson now "$NOW" --argjson max "$BACKUP_MAX_H" '[.items[] | select(.metadata.name | test("backup"))
    | {ns: .metadata.namespace, name: .metadata.name, suspended: (.spec.suspend // false),
       last_success: (.status.lastSuccessfulTime // null), last_schedule: (.status.lastScheduleTime // null),
       active: ((.status.active // []) | length)}
    | . + {age_h: (if .last_success then (($now - (.last_success | fromdateiso8601)) / 3600 | floor) else null end)}
    | . + {stale: ((.suspended | not) and (.age_h == null or .age_h > $max))}]
    | sort_by(.ns, .name)' "$T/cj.raw" > "$T/backups.json"

nas='[]'
for p in $NAS_PORTS; do
  o=false; tcp_open "$NAS_HOST" "$p" && o=true
  nas=$(jq -c --argjson p "$p" --argjson o "$o" '. + [{port: $p, open: $o}]' <<<"$nas")
done
jq -n -c --arg h "$NAS_HOST" --argjson ports "$nas" '{host: $h, ports: $ports}' > "$T/nas.json"

git_wan=$(wan_in_git "$ROOT")
w1=$(curl -sS -m 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
w2=$(curl -sS -m 10 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
is_ipv4 "$w1" || w1=""
is_ipv4 "$w2" || w2=""
cur=""
if [ -n "$w1" ] && { [ -z "$w2" ] || [ "$w1" = "$w2" ]; }; then cur=$w1; elif [ -z "$w1" ] && [ -n "$w2" ]; then cur=$w2; fi
jq -n -c --arg g "$git_wan" --arg c "$cur" --arg a "$w1" --arg b "$w2" \
  '{in_git: $g, current: (if $c == "" then null else $c end), sources: {ipify: $a, ifconfig_me: $b},
    match: (if $c == "" then null else ($c == $g) end)}' > "$T/wan.json"

immich=null
pod=$(k -n immich get pod -l cnpg.io/cluster=immich-db,role=primary -o name 2>/dev/null | head -n 1)
if [ -n "$pod" ]; then
  rows=$(k -n immich exec "${pod#pod/}" -c postgres -- env PGOPTIONS='-c default_transaction_read_only=on' \
    psql -d app -tAc 'select type, count(*) from asset where "deletedAt" is null group by type' 2>/dev/null)
  immich=$(printf '%s\n' "$rows" | awk -F'|' 'NF == 2 && $2 ~ /^[0-9]+$/ { printf "%s\t%s\n", $1, $2 }' \
    | jq -R -c 'split("\t") | {(.[0] | ascii_downcase): (.[1] | tonumber)}' | jq -c -s 'if length == 0 then null else add end')
fi
printf '%s\n' "${immich:-null}" > "$T/immich.json"

# Names, types and timestamps only: kubectl filters server output to these
# fields, so no Secret value reaches this script.
if ! k get secrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.type}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}' \
  2> "$T/secrets.err" > "$T/secrets.tsv"; then
  read_failed "secrets -A" "$T/secrets.err"
  : > "$T/secrets.tsv"
fi
jq -R -s -c 'split("\n") | map(select(length > 0))' "$T/errors.txt" > "$T/errors.json"
jq -R -c --argjson now "$NOW" 'split("\t") | select(length == 4)
    | {ns: .[0], name: .[1], type: .[2], age_d: (($now - (.[3] | fromdateiso8601)) / 86400 | floor)}' "$T/secrets.tsv" \
  | jq -s -c '[group_by(.ns)[] | {ns: .[0].ns, count: length,
      newest_d: (map(.age_d) | min), oldest: (max_by(.age_d) | {name, age_d})}]' > "$T/secrets.json"

jq -n -c \
  --slurpfile nodes "$T/nodes.json" --slurpfile etcd "$T/etcd.json" --slurpfile argo "$T/argo.json" \
  --slurpfile pods "$T/pods.json" --slurpfile pvc "$T/pvc.json" --slurpfile cnpg "$T/cnpg.json" \
  --slurpfile certs "$T/certs.json" --slurpfile gateway "$T/gateway.json" --slurpfile backups "$T/backups.json" \
  --slurpfile nas "$T/nas.json" --slurpfile wan "$T/wan.json" --slurpfile immich "$T/immich.json" \
  --slurpfile secrets "$T/secrets.json" --slurpfile errors "$T/errors.json" \
  --argjson now "$NOW" --argjson certwarn "$CERT_WARN_DAYS" '
  {schema: 1, generated: ($now | todate),
   nodes: $nodes[0], etcd: $etcd[0], argo: $argo[0], pods: $pods[0], pvcs: $pvc[0], cnpg: $cnpg[0],
   certificates: $certs[0], gateway: $gateway[0], backups: $backups[0], nas: $nas[0], wan: $wan[0],
   immich: $immich[0], secrets: $secrets[0], errors: $errors[0]}
  | .problems = ([
      (.errors[]),
      (.nodes[] | select((.ready | not) or .unschedulable) | "node \(.name) not Ready or cordoned"),
      (if .etcd.healthy == null then "etcd health unreadable" elif .etcd.healthy < .etcd.members then "etcd \(.etcd.healthy)/\(.etcd.members) healthy" else empty end),
      (if .etcd.vip_reachable then empty else "API VIP \(.etcd.vip):6443 unreachable" end),
      (.argo.bad[] | "Application \(.name) \(.sync)/\(.health)"),
      (.pods.bad[] | "pod \(.ns)/\(.name) \(.phase) \(.reason)"),
      (.pvcs.not_bound[] | "PVC \(.ns)/\(.name) \(.phase)"),
      (.cnpg[] | select(.phase != "Cluster in healthy state") | "CNPG \(.ns)/\(.name): \(.phase)"),
      (.certificates[] | select((.ready | not) or (.days != null and .days < $certwarn)) | "certificate \(.ns)/\(.name) ready=\(.ready) days=\(.days)"),
      (.gateway.gateways[] | select(.programmed | not) | "Gateway \(.ns)/\(.name) not Programmed"),
      (.gateway.routes[] | select(.accepted | not) | "HTTPRoute \(.ns)/\(.name) not Accepted"),
      (.backups[] | select(.stale) | "backup \(.ns)/\(.name) last success \(.age_h // "never")h ago"),
      (.nas.ports[] | select(.open | not) | "NAS \($nas[0].host):\(.port) closed"),
      (if .wan.match == false then "WAN \(.wan.current) != --default-targets \(.wan.in_git)" else empty end)
    ])' > "$T/status.json"

if [ "$JSON" = 1 ]; then
  jq . "$T/status.json"
  [ "$(jq '.problems | length' "$T/status.json")" -eq 0 ]
  exit $?
fi

# --- render -------------------------------------------------------------------
# Each jq filter prints "LEVEL<TAB>text"; LEVEL is ok, warn, bad or info.
show() {
  local lvl txt
  while IFS=$'\t' read -r lvl txt; do
    case "$lvl" in
      ok) ok "$txt" ;; warn) warn "$txt" ;; bad) bad "$txt" ;;
      *) printf '  %s\n' "$txt" ;;
    esac
  done < <(jq -r --argjson certwarn "$CERT_WARN_DAYS" "$1" "$T/status.json")
}

printf '%shomelab status%s  %s\n' "$C_CYAN" "$C_OFF" "$(jq -r .generated "$T/status.json")"

if [ "$(jq '.errors | length' "$T/status.json")" -gt 0 ]; then
  step "Reads that failed (their sections below are incomplete)"
  show '.errors[] | ["bad", .] | @tsv'
fi

step "Nodes"
show '.nodes[] | [(if .ready and (.unschedulable | not) then "ok" else "bad" end),
  "\(.name)  \(if .ready then "Ready" else "NotReady" end)\(if .unschedulable then ",cordoned" else "" end)  \(.ip)  \(.kubelet)  \(.kernel)  \(.runtime)"] | @tsv'
show '.etcd | [(if .healthy != null and .healthy == .members then "ok" else "bad" end), "etcd \(.healthy // "?")/\(.members // "?") healthy"],
  [(if .vip_reachable then "ok" else "bad" end), "API VIP \(.vip):6443 \(if .vip_reachable then "reachable" else "UNREACHABLE" end)"] | @tsv'

step "Argo CD"
show '.argo | if (.bad | length) == 0 then ["ok", "\(.total) Applications Synced/Healthy"] | @tsv
  else (.bad[] | ["bad", "\(.name)  \(.sync)/\(.health)"] | @tsv) end'

step "Pods"
show '.pods | if (.bad | length) == 0 then ["ok", "\(.total) pods, all Running or Completed"] | @tsv
  else (.bad[] | ["bad", "\(.ns)/\(.name)  \(.phase) \(.reason)  restarts=\(.restarts)"] | @tsv) end'
show '.pods.restarts[] | ["info", "restarts \(.restarts)  \(.ns)/\(.name)"] | @tsv'

step "Storage and databases"
show '.pvcs | [(if (.not_bound | length) == 0 then "ok" else "bad" end), "PVCs \(.bound)/\(.total) Bound"] | @tsv'
show '.pvcs.not_bound[] | ["bad", "  \(.ns)/\(.name) \(.phase)"] | @tsv'
show '[.cnpg[] | select(.phase != "Cluster in healthy state")] as $b
  | if ($b | length) == 0 then ["ok", "CNPG \(.cnpg | length) clusters healthy"] | @tsv
    else ($b[] | ["bad", "CNPG \(.ns)/\(.name)  \(.ready)/\(.instances)  \(.phase)"] | @tsv) end'
show '.nas | .host as $h | .ports[] | [(if .open then "ok" else "bad" end), "NAS \($h):\(.port) \(if .open then "open" else "CLOSED" end)"] | @tsv'
show 'if .immich == null then ["warn", "Immich counts unavailable"] else ["info", "Immich  \(.immich | to_entries | map("\(.key) \(.value)") | join("  "))"] end | @tsv'

step "Certificates"
show '.certificates[] | [(if (.ready | not) then "bad" elif .days != null and .days < $certwarn then "warn" else "ok" end),
  "\(.ns)/\(.name)  \(if .days == null then "no notAfter" else "\(.days)d" end)\(if .ready then "" else "  NOT READY" end)"] | @tsv'

step "Gateway and LoadBalancers"
show '.gateway.gateways[] | [(if .programmed then "ok" else "bad" end), "Gateway \(.ns)/\(.name)  \(.address)"] | @tsv'
show '[.gateway.routes[] | select(.accepted | not)] as $b
  | if ($b | length) == 0 then ["ok", "\(.gateway.routes | length) HTTPRoutes Accepted: \([.gateway.routes[].hosts[] | split(".")[0]] | unique | join(" "))"] | @tsv
    else ($b[] | ["bad", "HTTPRoute \(.ns)/\(.name) \(.hosts | join(",")) not Accepted"] | @tsv) end'
show '.gateway.loadbalancers[] | ["info", "LB \(.ips | join(",") | if . == "" then "<pending>" else . end)  \(.svc)"] | @tsv'

step "Backups (CronJobs)"
show '[.backups[] | select(.suspended | not)] as $live
  | ([$live[] | select(.stale)]) as $b
  | (if ($b | length) == 0 then ["ok", "\($live | length) backup CronJobs, oldest last success \([$live[].age_h] | max // "-")h ago"] | @tsv
     else ($b[] | ["bad", "\(.ns)/\(.name)  \(if .age_h == null then "never succeeded" else "last success \(.age_h)h ago" end)"] | @tsv) end),
    (.backups[] | select(.suspended) | ["info", "\(.ns)/\(.name)  suspended"] | @tsv),
    (.backups[] | select(.active > 0) | ["info", "\(.ns)/\(.name)  running now"] | @tsv)'

step "WAN"
show '.wan | if .current == null then ["warn", "current WAN unknown (ipify=\(.sources.ipify) ifconfig.me=\(.sources.ifconfig_me)); git has \(.in_git)"]
  elif .match then ["ok", "WAN \(.current) = --default-targets in infrastructure/external-dns/values.yaml"]
  else ["bad", "WAN \(.current) != --default-targets \(.in_git): docs/runbooks/wan-ip-change.md"] end | @tsv'

step "Secrets (names and ages only)"
show '["info", "\([.secrets[].count] | add // 0) Secrets in \(.secrets | length) namespaces; oldest per namespace:"] | @tsv'
show '[.secrets[] | {ns, name: .oldest.name, age_d: .oldest.age_d}] | sort_by(-.age_d) | .[0:3][]
  | ["info", "  \(.age_d)d  \(.ns)/\(.name)"] | @tsv'

n=$(jq '.problems | length' "$T/status.json")
echo
if [ "$n" -eq 0 ]; then ok "no problems"; else bad "$n problem(s)"; fi
[ "$n" -eq 0 ]
