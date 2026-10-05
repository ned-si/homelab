#!/bin/bash
# shellcheck disable=SC2329 # probe functions run through with_retry
# smoke.sh -- the read-only cluster smoke suite `S` (items 1-10).
#
# usage: scripts/smoke.sh --node-macs <file> --immich-sql <file> --argo-gate <file>
#                         --entry-ip <ip> [--previous <json>] [--pod-exclude <file>]
#
# Every command is read-only: `kubectl get`, `kubectl exec` of read-only
# commands (etcdctl endpoint health, psql with default_transaction_read_only=on,
# a file-existence loop), read-only SSH (`ip -4 -o addr show`), curl, dig,
# nc -z, ping, arp -n. Every network call is bounded (kubectl
# --request-timeout=10s, curl -m 10, ssh ConnectTimeout=5 BatchMode=yes,
# nc -G 3, dig +time=3); network checks retry 3 times over about 60 s.
#
# Output: one JSON document on stdout; progress goes to stderr. Exit 0 when
# every item passes, 1 when any item fails, 64 on a usage or input error.
#
# Inputs are local files passed as arguments and never committed:
#   --node-macs    lines "<node> <mac>": the node MAC set N (item 9)
#   --immich-sql   lines "<KEY>: <sql>" with KEY Q1, Q2, Q3 and ORIG (item 8);
#                  Q3 contains the literal <previous run UTC>
#   --argo-gate    lines "<application> <sync+health|health>" (item 6);
#                  blank lines and lines starting with # are ignored
#   --entry-ip     the address the router forwards 80/443 to (items 7 and 9)
#   --previous     an earlier smoke.sh JSON. Item 4 (PVC count), item 8
#                  (Immich counts), item 7 (the HTTP baseline, carried forward
#                  from the first run of the chain) and item 9 (binding
#                  holders, INFO only) compare against it
#   --pod-exclude  optional, lines "<namespace>/<pod-name-prefix>" (item 3)
#
# Original paths (item 8) are piped through stdin only: never printed,
# written or put on argv. The JSON holds names, counts, codes and node names.
#
# Requires bash 3.2+, jq, kubectl, ssh, curl, dig, nc, ping, arp, openssl
# (macOS flags: nc -G, ping -W in milliseconds).
set -uo pipefail

SSH_USER=${SMOKE_SSH_USER:-nedsi}
API_VIP=${SMOKE_API_VIP:-192.168.1.11}
DOMAIN=${SMOKE_DOMAIN:-lilalala.com}
HOSTS=${SMOKE_HOSTS:-"argo auth grafana theater cinema media archive cook drive syncthing"}
NODE_COUNT=${SMOKE_NODE_COUNT:-4}
ETCD_MEMBERS=${SMOKE_ETCD_MEMBERS:-3}
PVC_MIN=${SMOKE_PVC_MIN:-26}
CNPG_MIN=${SMOKE_CNPG_MIN:-7}
PUBLIC_TCP=${SMOKE_PUBLIC_TCP:-"22000 443"}
CERT_MIN_DAYS=${SMOKE_CERT_MIN_DAYS:-14}
RETRY_SLEEP=${SMOKE_RETRY_SLEEP:-20}
ARP_SAMPLES=${SMOKE_ARP_SAMPLES:-6}
ARP_INTERVAL=${SMOKE_ARP_INTERVAL:-10}
PENDING_MAX_S=300
PLACEHOLDER='<previous run UTC>'

usage() {
  echo "usage: $0 --node-macs <file> --immich-sql <file> --argo-gate <file> --entry-ip <ip> [--previous <json>] [--pod-exclude <file>]" >&2
  exit 64
}
die() { echo "smoke: $*" >&2; exit 64; }
log() { echo "smoke: $*" >&2; }

NODE_MACS="" IMMICH_SQL="" ARGO_GATE="" ENTRY_IP="" PREVIOUS="" POD_EXCLUDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --node-macs) [ "$#" -ge 2 ] || usage; NODE_MACS=$2; shift ;;
    --immich-sql) [ "$#" -ge 2 ] || usage; IMMICH_SQL=$2; shift ;;
    --argo-gate) [ "$#" -ge 2 ] || usage; ARGO_GATE=$2; shift ;;
    --entry-ip) [ "$#" -ge 2 ] || usage; ENTRY_IP=$2; shift ;;
    --previous) [ "$#" -ge 2 ] || usage; PREVIOUS=$2; shift ;;
    --pod-exclude) [ "$#" -ge 2 ] || usage; POD_EXCLUDE=$2; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done
[ -n "$NODE_MACS" ] && [ -n "$IMMICH_SQL" ] && [ -n "$ARGO_GATE" ] && [ -n "$ENTRY_IP" ] || usage

is_ipv4() {
  printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
  local IFS=. o
  for o in $1; do [ "$o" -le 255 ] || return 1; done
}

# Lower-case, two hex digits per octet (macOS arp drops leading zeros).
norm_mac() {
  printf '%s\n' "$1" | tr 'A-F' 'a-f' | awk -F: 'NF == 6 {
    s = ""; for (i = 1; i <= 6; i++) { x = $i; if (length(x) == 1) x = "0" x; if (x !~ /^[0-9a-f][0-9a-f]$/) exit; s = s (i > 1 ? ":" : "") x }
    print s }'
}

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- input validation (exit 64 before anything runs) --------------------------
is_ipv4 "$ENTRY_IP" || die "--entry-ip is not an IPv4 address"
[ -f "$NODE_MACS" ] || die "--node-macs: no such file"
[ -f "$IMMICH_SQL" ] || die "--immich-sql: no such file"
[ -f "$ARGO_GATE" ] || die "--argo-gate: no such file"
[ -z "$POD_EXCLUDE" ] || [ -f "$POD_EXCLUDE" ] || die "--pod-exclude: no such file"
if [ -n "$PREVIOUS" ]; then
  [ -f "$PREVIOUS" ] || die "--previous: no such file"
  jq -e '.schema == 1 and (.items | type == "array")' "$PREVIOUS" >/dev/null 2>&1 || die "--previous is not a smoke.sh JSON document"
fi

RES=$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$RES"' EXIT
: > "$RES/info.txt"
: > "$RES/hard.txt"

# N: node MAC set, "<mac> <node>" per line.
while read -r node mac rest; do
  case "$node" in ''|'#'*) continue ;; esac
  m=$(norm_mac "${mac:-}")
  [ -n "$m" ] && [ -z "${rest:-}" ] || die "--node-macs: malformed line for '$node'"
  echo "$m $node" >> "$RES/macs.txt"
done < "$NODE_MACS"
[ -s "$RES/macs.txt" ] || die "--node-macs holds no MAC"

sql_get() { sed -n "s/^$1: //p" "$IMMICH_SQL" | head -n 1; }
Q1=$(sql_get Q1); Q2=$(sql_get Q2); Q3=$(sql_get Q3); ORIG=$(sql_get ORIG)
[ -n "$Q1" ] && [ -n "$Q2" ] && [ -n "$Q3" ] && [ -n "$ORIG" ] || die "--immich-sql must define Q1, Q2, Q3 and ORIG"
case "$Q3" in *"$PLACEHOLDER"*) ;; *) die "--immich-sql: Q3 lacks $PLACEHOLDER" ;; esac

prev() { # prev <jq filter>: evaluate against --previous, or print null
  if [ -n "$PREVIOUS" ]; then jq -c "$1" "$PREVIOUS"; else echo null; fi
}

STARTED=$(utc_now)
NOW=${SMOKE_NOW:-$(date -u +%s)}

k() { kubectl --request-timeout=10s "$@"; }

reason() { printf '%s\n' "$2" >> "$RES/reasons-$1"; }    # reason <item> <text>
info() { printf '%s\n' "$*" >> "$RES/info.txt"; }
hard() { printf '%s\n' "$*" >> "$RES/hard.txt"; }
finish_item() { # finish_item <id> <name> <detail-json>
  local f="$RES/reasons-$1" pass=true fails='[]'
  if [ -s "$f" ]; then pass=false; fails=$(jq -R . < "$f" | jq -cs .); fi
  jq -n --argjson id "$1" --arg name "$2" --argjson pass "$pass" --argjson failures "$fails" \
    --argjson detail "${3:-null}" '{id: $id, name: $name, pass: $pass, failures: $failures, detail: $detail}' \
    > "$RES/item-$(printf %02d "$1").json"
  log "item $1 ($2): $([ "$pass" = true ] && echo pass || echo FAIL)"
}

# with_retry <cmd...>: run up to 3 times, RETRY_SLEEP apart, until it exits 0.
with_retry() {
  local i=1
  while :; do
    "$@" && return 0
    [ "$i" -ge 3 ] && return 1
    i=$((i + 1))
    sleep "$RETRY_SLEEP"
  done
}

# --- 1. nodes -------------------------------------------------------------------
item_nodes() {
  local j d
  if ! j=$(k get nodes -o json 2>/dev/null); then
    reason 1 "kubectl get nodes failed"; finish_item 1 nodes null; return
  fi
  d=$(jq -c '[.items[] | {name: .metadata.name,
      ready: ([.status.conditions[]? | select(.type == "Ready") | .status][0] == "True"),
      unschedulable: (.spec.unschedulable // false),
      version: .status.nodeInfo.kubeletVersion,
      ip: ([.status.addresses[]? | select(.type == "InternalIP") | .address][0])}]' <<<"$j")
  jq -r '.[] | "\(.name) \(.ip)"' <<<"$d" > "$RES/nodes.txt"
  [ "$(jq length <<<"$d")" -eq "$NODE_COUNT" ] || reason 1 "expected $NODE_COUNT nodes, found $(jq length <<<"$d")"
  jq -r '.[] | select(.ready | not) | "node \(.name) is not Ready"' <<<"$d" >> "$RES/reasons-1"
  jq -r '.[] | select(.unschedulable) | "node \(.name) is SchedulingDisabled"' <<<"$d" >> "$RES/reasons-1"
  finish_item 1 nodes "$d"
}

# --- 2. etcd and the API VIP ----------------------------------------------------
item_etcd() {
  local pods p out healthy=null total=null vip=false
  pods=$(k -n kube-system get pods -l component=etcd -o name 2>/dev/null)
  out=""
  for p in $pods; do
    out=$(k -n kube-system exec "${p#pod/}" -- etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
      --key=/etc/kubernetes/pki/etcd/healthcheck-client.key endpoint health --cluster -w json 2>/dev/null) \
      && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 && break
    out=""
  done
  if [ -z "$out" ]; then
    reason 2 "etcdctl endpoint health --cluster failed on every etcd pod"
    hard "etcd health unreadable"
  else
    total=$(jq length <<<"$out")
    healthy=$(jq '[.[] | select(.health == true)] | length' <<<"$out")
    if [ "$healthy" -lt "$ETCD_MEMBERS" ] || [ "$total" -ne "$ETCD_MEMBERS" ]; then
      reason 2 "etcd $healthy/$total healthy, expected $ETCD_MEMBERS/$ETCD_MEMBERS"
      hard "etcd quorum below $ETCD_MEMBERS healthy"
    fi
  fi
  if with_retry nc -z -G 3 "$API_VIP" 6443 >/dev/null 2>&1; then vip=true; else
    reason 2 "API VIP $API_VIP:6443 unreachable"; hard "API VIP unreachable"
  fi
  finish_item 2 etcd "$(jq -n --argjson h "$healthy" --argjson t "$total" --argjson vip "$vip" \
    --arg ip "$API_VIP" '{healthy: $h, members: $t, vip: $ip, vip_reachable: $vip}')"
}

# --- 3. pods --------------------------------------------------------------------
item_pods() {
  local j excl='[]' d
  if ! j=$(k get pods -A -o json 2>/dev/null); then
    reason 3 "kubectl get pods failed"; finish_item 3 pods null; return
  fi
  if [ -n "$POD_EXCLUDE" ]; then
    excl=$(grep -Ev '^[[:space:]]*(#|$)' "$POD_EXCLUDE" | jq -R . | jq -cs .)
  fi
  d=$(jq -c --argjson now "$NOW" --argjson max "$PENDING_MAX_S" --argjson excl "$excl" '
    [.items[]
     | {ns: .metadata.namespace, name: .metadata.name, phase: .status.phase,
        age: ($now - (.metadata.creationTimestamp | fromdateiso8601)),
        bad: [(.status.initContainerStatuses // [])[], (.status.containerStatuses // [])[]
              | .state.waiting.reason // empty
              | select(. == "CrashLoopBackOff" or . == "ImagePullBackOff" or . == "ErrImagePull")]}
     | select((.bad | length) > 0 or (.phase == "Pending" and .age > $max))
     | . as $p | select([$excl[] | . as $e | ($p.ns + "/" + $p.name) | startswith($e)] | any | not)
     | {ns, name, phase, reasons: .bad, age_s: .age}]' <<<"$j")
  jq -r '.[] | "pod \(.ns)/\(.name): \(.phase) \(.reasons | join(","))"' <<<"$d" >> "$RES/reasons-3"
  finish_item 3 pods "$(jq -c --argjson total "$(jq '.items | length' <<<"$j")" '{total: $total, bad: .}' <<<"$d")"
}

# --- 4. PVCs --------------------------------------------------------------------
item_pvcs() {
  local j d bound want p
  if ! j=$(k get pvc -A -o json 2>/dev/null); then
    reason 4 "kubectl get pvc failed"; hard "PVCs unreadable"; finish_item 4 pvcs null; return
  fi
  d=$(jq -c '{bound: ([.items[] | select(.status.phase == "Bound")] | length),
              not_bound: [.items[] | select(.status.phase != "Bound") | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"]}' <<<"$j")
  bound=$(jq .bound <<<"$d")
  want=$PVC_MIN
  p=$(prev '[.items[] | select(.id == 4) | .detail.bound // empty][0] // null')
  if [ "$p" != null ] && [ "$p" -gt "$want" ]; then want=$p; fi
  [ "$bound" -ge "$want" ] || reason 4 "$bound PVCs Bound, expected at least $want"
  if [ "$(jq '.not_bound | length' <<<"$d")" -gt 0 ]; then
    jq -r '.not_bound[] | "PVC \(.) is not Bound"' <<<"$d" >> "$RES/reasons-4"
    hard "a PVC is not Bound"
  fi
  finish_item 4 pvcs "$(jq -c --argjson want "$want" '. + {expected_min: $want}' <<<"$d")"
}

# --- 5. CNPG clusters and the seafile database ----------------------------------
item_databases() {
  local j d m mready=null want p
  if ! j=$(k get clusters.postgresql.cnpg.io -A -o json 2>/dev/null); then
    reason 5 "kubectl get clusters.postgresql.cnpg.io failed"; j='{"items":[]}'
  fi
  d=$(jq -c '[.items[] | {ns: .metadata.namespace, name: .metadata.name, phase: (.status.phase // "")}]' <<<"$j")
  want=$CNPG_MIN
  p=$(prev '[.items[] | select(.id == 5) | .detail.cnpg | length][0] // null')
  if [ "$p" != null ] && [ "$p" -gt "$want" ]; then want=$p; fi
  [ "$(jq length <<<"$d")" -ge "$want" ] || reason 5 "$(jq length <<<"$d") CNPG clusters, expected at least $want"
  jq -r '.[] | select(.phase != "Cluster in healthy state") | "CNPG \(.ns)/\(.name): \(.phase)"' <<<"$d" >> "$RES/reasons-5"
  if m=$(k -n seafile get deploy mariadb -o json 2>/dev/null); then
    mready=$(jq -c '{replicas: (.spec.replicas // 1), ready: (.status.readyReplicas // 0)}' <<<"$m")
    jq -e '.ready >= 1 and .ready == .replicas' <<<"$mready" >/dev/null || reason 5 "seafile/mariadb not Ready"
  else
    reason 5 "seafile/mariadb not found"
  fi
  finish_item 5 databases "$(jq -n --argjson c "$d" --argjson m "$mready" '{cnpg: $c, seafile_mariadb: $m}')"
}

# --- 6. Argo CD -----------------------------------------------------------------
item_argo() {
  local j apps gate='[]' line name mode extra n=0
  # Gate file: "<name> <mode>" per line; a malformed file fails item 6.
  : > "$RES/gate.txt"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    name="" mode="" extra=""
    read -r name mode extra <<<"$line"
    if [ -n "$extra" ] || ! printf '%s' "$name" | grep -Eq '^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$' \
       || { [ "$mode" != "sync+health" ] && [ "$mode" != "health" ]; }; then
      reason 6 "--argo-gate line $n is malformed (want '<application> <sync+health|health>')"
      continue
    fi
    if awk -v n="$name" '$1 == n { f = 1 } END { exit !f }' "$RES/gate.txt"; then
      reason 6 "--argo-gate names $name twice"
      continue
    fi
    echo "$name $mode" >> "$RES/gate.txt"
  done < "$ARGO_GATE"
  [ -s "$RES/gate.txt" ] || reason 6 "--argo-gate lists no Application"
  gate=$(jq -R 'split(" ") | {name: .[0], mode: .[1]}' < "$RES/gate.txt" | jq -cs .)
  if ! j=$(k -n argo get applications -o json 2>/dev/null); then
    reason 6 "kubectl get applications failed"; j='{"items":[]}'
  fi
  apps=$(jq -c '[.items[] | {name: .metadata.name, sync: (.status.sync.status // "Unknown"),
      health: (.status.health.status // "Unknown"),
      conditions: [.status.conditions[]? | .type | select(. == "InvalidSpecError" or . == "ComparisonError" or . == "SyncError")]}]' <<<"$j")
  jq -r '.[] | select(.conditions | length > 0) | "Application \(.name) has condition \(.conditions | join(","))"' <<<"$apps" >> "$RES/reasons-6"
  jq -r --argjson gate "$gate" '. as $apps | $gate[] | . as $g
    | ([$apps[] | select(.name == $g.name)][0]) as $a
    | if $a == null then "gated Application \($g.name) does not exist"
      elif $g.mode == "sync+health" and ($a.sync != "Synced" or $a.health != "Healthy") then "gated Application \($g.name) is \($a.sync)/\($a.health), want Synced/Healthy"
      elif $g.mode == "health" and $a.health != "Healthy" then "gated Application \($g.name) is \($a.health), want Healthy"
      else empty end' <<<"$apps" >> "$RES/reasons-6"
  jq -r --argjson gate "$gate" '.[] | select(.name as $n | [$gate[].name] | index($n) | not)
    | select(.sync != "Synced" or .health != "Healthy") | "Application \(.name) is \(.sync)/\(.health) (not gated, reported)"' <<<"$apps" >> "$RES/info.txt"
  jq -n --argjson apps "$apps" --argjson gate "$gate" --arg sha "$(sha256 < "$ARGO_GATE")" \
    '{gate_file_sha256: $sha, gate: $gate, applications: $apps}' > "$RES/argo.json"
  finish_item 6 argo "$(cat "$RES/argo.json")"
}

# --- 10 (first: items 7 and 9 need the WAN) -- public address and DNS -----------
WAN=""
read_wan() {
  local j t
  j=$(k -n external-dns get deploy external-dns -o json 2>/dev/null) || return 1
  t=$(jq -r '.spec.template.spec.containers[0].args[]? // empty' <<<"$j" | sed -n 's/^--default-targets=//p')
  [ "$(printf '%s\n' "$t" | grep -c .)" -eq 1 ] && is_ipv4 "$t" || return 1
  WAN=$t
}

dig_one() { # dig_one <name> <want>: the complete A-record set is exactly {<want>}
  # Every IPv4 answer counts: one stale address next to the expected one fails,
  # because a client may pick either. Non-address lines (a CNAME target, a dig
  # error message) are not addresses and are dropped. The set is saved sorted
  # and comma-separated; a single address is saved as itself.
  local got
  got=$(dig +short +time=3 +tries=1 "$1" @1.1.1.1 2>/dev/null \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | paste -s -d , -)
  printf '%s' "$got" > "$RES/dig-$1"
  [ "$got" = "$2" ]
}

item_dns() {
  local h fqdn got d='[]' s1 s2
  if [ -z "$WAN" ]; then
    reason 10 "cannot read exactly one IPv4 --default-targets from external-dns"
    finish_item 10 dns null; return
  fi
  for h in $HOSTS; do
    fqdn="$h.$DOMAIN"
    if ! with_retry dig_one "$fqdn" "$WAN"; then
      reason 10 "$fqdn resolves to '$(cat "$RES/dig-$fqdn")' at 1.1.1.1, want the WAN address"
    fi
    got=$(cat "$RES/dig-$fqdn")
    d=$(jq -c --arg h "$fqdn" --arg a "$got" '. + [{name: $h, answer: $a}]' <<<"$d")
  done
  if [ -s "$RES/reasons-10" ]; then
    # The design's WAN rule needs both independent sources.
    s1=$(curl -sS -m 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    s2=$(curl -sS -m 10 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
    if [ -n "$s1" ] && [ "$s1" = "$s2" ] && [ "$s1" != "$WAN" ]; then
      info "WAN rule: api.ipify.org and ifconfig.me agree on $s1, external-dns --default-targets is $WAN"
    fi
    d=$(jq -c --arg a "$s1" --arg b "$s2" '{answers: ., wan_sources: {ipify: $a, ifconfig_me: $b}}' <<<"$d")
  else
    d=$(jq -c '{answers: .}' <<<"$d")
  fi
  finish_item 10 dns "$(jq -c --arg wan "$WAN" '. + {wan: $wan}' <<<"$d")"
}

# --- 7. HTTP matrix ---------------------------------------------------------------
# scheme_host <url>: "<scheme>://<authority>", without the scheme's default port
# (RFC 3986 6.2.3: https://h:443 and https://h are the same URL). Cilium's
# Gateway puts ":443" in its HTTP->HTTPS redirect Location; ingress-nginx does not.
scheme_host() {
  printf '%s' "$1" | sed -n 's#^\([A-Za-z][A-Za-z0-9+.-]*://[^/?#]*\).*#\1#p' \
    | sed -e 's#^\([Hh][Tt][Tt][Pp][Ss]://.*\):443$#\1#' -e 's#^\([Hh][Tt][Tt][Pp]://.*\):80$#\1#'
}

https_probe() { # https_probe <fqdn> <ip> <key>: writes <key>.code/.loc/.cert, 0 when curl got an answer
  local out rc code loc
  out=$(curl -sS -m 10 --connect-timeout 5 -o /dev/null --resolve "$1:443:$2" \
        -w '%{http_code} %{redirect_url}\n%{certs}' "https://$1/" 2>/dev/null); rc=$?
  code=$(printf '%s\n' "$out" | head -n 1 | cut -d' ' -f1)
  loc=$(printf '%s\n' "$out" | head -n 1 | cut -s -d' ' -f2-)
  printf '%s' "${code:-000}" > "$RES/$3.code"
  scheme_host "$loc" > "$RES/$3.loc"
  if printf '%s\n' "$out" | awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{exit}' \
      | openssl x509 -noout -checkend $((CERT_MIN_DAYS * 86400)) >/dev/null 2>&1; then
    echo true > "$RES/$3.cert"
  else
    echo false > "$RES/$3.cert"
  fi
  [ "$rc" -eq 0 ] && [ "${code:-000}" != 000 ]
}

http_probe() { # http_probe <fqdn> <ip> <key>: 0 when http:// answers 301/308 to https://<fqdn>
  local out code loc
  out=$(curl -sS -m 10 --connect-timeout 5 -o /dev/null --resolve "$1:80:$2" \
        -w '%{http_code} %{redirect_url}' "http://$1/" 2>/dev/null)
  code=$(printf '%s' "$out" | cut -d' ' -f1)
  loc=$(printf '%s' "$out" | cut -s -d' ' -f2-)
  printf '%s' "${code:-000}" > "$RES/$3.code"
  scheme_host "$loc" > "$RES/$3.loc"
  { [ "$code" = 301 ] || [ "$code" = 308 ]; } && [ "$(scheme_host "$loc")" = "https://$1" ]
}

# entry_ok <fqdn> <key> <baseline code> <baseline loc>
probe_matches() {
  https_probe "$1" "$2" "$3" || return 1
  [ "$(cat "$RES/$3.cert")" = true ] || return 1
  if [ "$4" != null ]; then
    [ "$(cat "$RES/$3.code")" = "$4" ] && [ "$(cat "$RES/$3.loc")" = "$5" ]
  else
    [ "$(cat "$RES/$3.code")" -lt 500 ]
  fi
}

item_http() {
  local h fqdn base bcode bloc pcode ploc pub d='{}' row
  base=$(prev '.baseline.http // null')
  for h in $HOSTS; do
    fqdn="$h.$DOMAIN"
    bcode=null; bloc=null; pcode=null; ploc=null
    if [ "$base" != null ]; then
      bcode=$(jq -r --arg h "$fqdn" '.[$h].entry.code // "null"' <<<"$base")
      bloc=$(jq -r --arg h "$fqdn" '.[$h].entry.loc // ""' <<<"$base")
      pcode=$(jq -r --arg h "$fqdn" '.[$h].public.code // "null"' <<<"$base")
      ploc=$(jq -r --arg h "$fqdn" '.[$h].public.loc // ""' <<<"$base")
    fi
    if ! with_retry probe_matches "$fqdn" "$ENTRY_IP" "e-$h" "$bcode" "$bloc"; then
      reason 7 "https://$fqdn via $ENTRY_IP: $(cat "$RES/e-$h.code") $(cat "$RES/e-$h.loc") cert_ok=$(cat "$RES/e-$h.cert") (baseline $bcode $bloc)"
    fi
    if ! with_retry http_probe "$fqdn" "$ENTRY_IP" "r-$h"; then
      reason 7 "http://$fqdn via $ENTRY_IP: $(cat "$RES/r-$h.code") $(cat "$RES/r-$h.loc"), want 301/308 to https://$fqdn"
    fi
    pub=""
    [ -f "$RES/dig-$fqdn" ] && pub=$(cat "$RES/dig-$fqdn")
    if is_ipv4 "$pub"; then
      if [ "$pcode" = null ]; then pcode=$(cat "$RES/e-$h.code"); ploc=$(cat "$RES/e-$h.loc"); fi
      if ! with_retry probe_matches "$fqdn" "$pub" "p-$h" "$pcode" "$ploc"; then
        reason 7 "https://$fqdn via public DNS: $(cat "$RES/p-$h.code") $(cat "$RES/p-$h.loc") cert_ok=$(cat "$RES/p-$h.cert") (want $pcode $ploc)"
      fi
    else
      # Not exactly one address: nothing is probed, because picking one of
      # several published addresses would hide the others.
      printf '000' > "$RES/p-$h.code"; : > "$RES/p-$h.loc"; echo false > "$RES/p-$h.cert"
      if [ -z "$pub" ]; then
        reason 7 "https://$fqdn via public DNS: no public answer"
      else
        reason 7 "https://$fqdn via public DNS: answer set '$pub' is not a single address, not probed"
      fi
    fi
    row=$(jq -n --arg ec "$(cat "$RES/e-$h.code")" --arg el "$(cat "$RES/e-$h.loc")" --argjson ecert "$(cat "$RES/e-$h.cert")" \
      --arg rc "$(cat "$RES/r-$h.code")" --arg rl "$(cat "$RES/r-$h.loc")" \
      --arg pc "$(cat "$RES/p-$h.code")" --arg pl "$(cat "$RES/p-$h.loc")" --argjson pcert "$(cat "$RES/p-$h.cert")" \
      '{entry: {code: $ec, loc: $el, cert_ok: $ecert}, http: {code: $rc, loc: $rl}, public: {code: $pc, loc: $pl, cert_ok: $pcert}}')
    d=$(jq -c --arg h "$fqdn" --argjson r "$row" '. + {($h): $r}' <<<"$d")
  done
  printf '%s' "$d" > "$RES/http.json"
  finish_item 7 http "$(jq -c --arg ip "$ENTRY_IP" '{entry_ip: $ip, hosts: .}' <<<"$d")"
}

# --- 8. Immich data -----------------------------------------------------------------
psql_ro() { # psql_ro <pod> <sql>
  k -n immich exec "$1" -c postgres -- env PGOPTIONS='-c default_transaction_read_only=on' psql -d app -tAc "$2"
}

counts_json() { # "TYPE|n" lines on stdin -> {"TYPE": n}
  awk -F'|' 'NF == 2 && $2 ~ /^[0-9]+$/ { printf "%s\t%s\n", $1, $2 }' | jq -R 'split("\t") | {(.[0]): (.[1] | tonumber)}' | jq -cs 'add // {}'
}

item_immich() {
  local pod q1 q2 prevq1 prevts dec=0 audit=null paths n missing q3
  pod=$(k -n immich get pod -l cnpg.io/cluster=immich-db,role=primary -o name 2>/dev/null)
  if [ "$(printf '%s\n' "$pod" | grep -c .)" -ne 1 ]; then
    reason 8 "expected exactly one immich-db primary pod"; finish_item 8 immich null; return
  fi
  pod=${pod#pod/}
  q1=$(psql_ro "$pod" "$Q1" 2>/dev/null | counts_json)
  q2=$(psql_ro "$pod" "$Q2" 2>/dev/null | counts_json)
  [ "$q1" != '{}' ] || reason 8 "Q1 returned no rows"
  prevq1=$(prev '[.items[] | select(.id == 8) | .detail.q1 // empty][0] // null')
  prevts=$(prev '.finished // null' | tr -d '"')
  if [ "$prevq1" != null ] && [ "$q1" != '{}' ]; then
    dec=$(jq -n --argjson a "$prevq1" --argjson b "$q1" '[$a | to_entries[] | (.value - ($b[.key] // 0)) | select(. > 0)] | add // 0')
    if [ "$dec" -gt 0 ]; then
      if printf '%s' "$prevts" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
        q3=$(printf '%s\n' "$Q3" | sed "s/$PLACEHOLDER/$prevts/")
        audit=$(psql_ro "$pod" "$q3" 2>/dev/null | tr -d '[:space:]')
        printf '%s' "$audit" | grep -Eq '^[0-9]+$' || audit=null
      fi
      if [ "$audit" = null ] || [ "$dec" -gt "$audit" ]; then
        reason 8 "unexplained Immich asset decrease: $dec fewer than the previous run, $audit audit rows since it"
        hard "unexplained Immich asset decrease"
      else
        info "Immich: $dec fewer assets than the previous run, explained by $audit asset_audit rows"
      fi
    fi
  fi
  # Originals: paths stay in this variable and go to the pod on stdin only.
  paths=$(psql_ro "$pod" "$ORIG" 2>/dev/null)
  n=$(printf '%s\n' "$paths" | grep -c .)
  # shellcheck disable=SC2016 # $p and $m expand in the pod's shell
  missing=$(printf '%s\n' "$paths" | k -n immich exec -i deploy/immich-server -- \
    sh -c 'm=0; while IFS= read -r p; do [ -f "$p" ] || m=$((m+1)); done; echo "$m"' 2>/dev/null | tr -d '[:space:]')
  paths=""
  [ "$n" -ge 1 ] || reason 8 "the originals query returned no rows"
  [ "$missing" = 0 ] || reason 8 "${missing:-?} of $n sampled originals are missing"
  finish_item 8 immich "$(jq -n --argjson q1 "$q1" --argjson q2 "$q2" --argjson dec "$dec" --argjson audit "$audit" \
    --argjson n "$n" --arg missing "${missing:-}" \
    '{q1: $q1, q2: $q2, q1_total: ([$q1[]] | add // 0), decrease: $dec, audit_rows: $audit, originals_sampled: $n, originals_missing: $missing}')"
}

# --- 9. LoadBalancer addresses and their binding ---------------------------------------
arp_mac() { # arp_mac <ip>: one ping, then the MAC from `arp -n` (normalised), or nothing
  ping -c 1 -W 1000 "$1" >/dev/null 2>&1
  norm_mac "$(arp -n "$1" 2>/dev/null | sed -n 's/.* at \([0-9A-Fa-f:]*\) on .*/\1/p' | head -n 1)"
}

mac_sample() { # mac_sample <ip>: retries ×3 on (incomplete); writes the node name
  local m node
  m=$(arp_mac "$1")
  [ -n "$m" ] || return 1
  node=$(awk -v m="$m" '$1 == m { print $2; exit }' "$RES/macs.txt")
  printf '%s %s\n' "$m" "${node:-}" > "$RES/mac-now"
}

ssh_addrs() { # ssh_addrs <node> <ip>
  # -n: ssh must not read the caller's stdin (the node list being looped over).
  ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$2" 'ip -4 -o addr show' 2>/dev/null \
    | awk '{ print $4 }' | cut -d/ -f1 > "$RES/addr-$1" && [ -s "$RES/addr-$1" ]
}

item_lb() {
  local j svcs ips ip node nip holders nh viphost prevh r s m nodeseen d='[]' port tcpok first
  if ! j=$(k get svc -A -o json 2>/dev/null); then
    reason 9 "kubectl get svc failed"; finish_item 9 lb null; return
  fi
  svcs=$(jq -c '[.items[] | select(.spec.type == "LoadBalancer")
    | {svc: "\(.metadata.namespace)/\(.metadata.name)",
       want: ((.metadata.annotations["lbipam.cilium.io/ips"] // "") | split(",") | map(gsub(" "; "")) | map(select(. != "")) | sort),
       got: ([.status.loadBalancer.ingress[]?.ip // empty] | sort),
       viphost: (.metadata.annotations["kube-vip.io/vipHost"] // ""),
       tcp: [.spec.ports[]? | select((.protocol // "TCP") == "TCP") | .port]}]' <<<"$j")
  jq -r '.[] | select((.want | length) > 0 and .want != .got) | "Service \(.svc) requests \(.want | join(",")) but has \(.got | join(",") | if . == "" then "none" else . end)"' <<<"$svcs" >> "$RES/reasons-9"
  ips=$( { jq -r '.[].got[]' <<<"$svcs"; echo "$ENTRY_IP"; } | sort -u)
  jq -e --arg ip "$ENTRY_IP" '[.[].got[]] | index($ip)' <<<"$svcs" >/dev/null || reason 9 "entry IP $ENTRY_IP is in no LoadBalancer Service status"

  # (a) interface holders, one read-only SSH per node.
  while read -r node nip; do
    [ -n "$node" ] || continue
    with_retry ssh_addrs "$node" "$nip" || { reason 9 "cannot read the addresses of $node over SSH"; : > "$RES/addr-$node"; }
  done < "$RES/nodes.txt"

  # (b) MAC samples: every LB address once per round.
  r=1
  while [ "$r" -le "$ARP_SAMPLES" ]; do
    for ip in $ips; do
      if with_retry mac_sample "$ip"; then
        read -r m node < "$RES/mac-now"
        if [ -z "${node:-}" ]; then
          reason 9 "$ip answered from MAC $m, which is not a node MAC"
        else
          echo "$node" >> "$RES/seen-$ip"
        fi
      else
        reason 9 "$ip: no ARP entry ((incomplete)) after 3 tries in sample $r"
      fi
    done
    [ "$r" -lt "$ARP_SAMPLES" ] && sleep "$ARP_INTERVAL"
    r=$((r + 1))
  done

  for ip in $ips; do
    s=$(jq -r --arg ip "$ip" '[.[] | select(.got | index($ip))][0].svc // ""' <<<"$svcs")
    viphost=$(jq -r --arg ip "$ip" '[.[] | select(.got | index($ip))][0].viphost // ""' <<<"$svcs")
    holders=$(cd "$RES" && grep -lxF "$ip" addr-* 2>/dev/null | sed 's/^addr-//' | sort | tr '\n' ' ' | sed 's/ $//')
    nh=$(printf '%s' "$holders" | wc -w | tr -d ' ')
    if [ "$nh" -gt 1 ]; then
      reason 9 "$ip is on the interfaces of $holders (more than one node)"
    elif [ "$nh" -eq 1 ] && [ -n "$viphost" ] && [ "$holders" != "$viphost" ]; then
      reason 9 "$ip is held by $holders, but $s names kube-vip.io/vipHost $viphost"
    elif [ "$nh" -eq 0 ]; then
      info "$ip is on no node interface (answered by Cilium L2 announcements)"
    fi
    prevh="<none>"
    if [ -n "$PREVIOUS" ]; then
      prevh=$(jq -r --arg ip "$ip" '[.items[] | select(.id == 9) | .detail.bindings[]? | select(.ip == $ip) | .holders][0] // "<none>"' "$PREVIOUS")
    fi
    if [ "$prevh" != "<none>" ] && [ "$prevh" != "$holders" ]; then
      info "$ip interface holder moved: '$prevh' -> '$holders'"
    fi
    nodeseen=$(sort -u "$RES/seen-$ip" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    if [ "$(printf '%s' "$nodeseen" | wc -w | tr -d ' ')" -gt 1 ]; then
      info "$ip ARP answers moved between nodes: $nodeseen"
    fi
    # (c) TCP: the HTTP matrix covers the entry IP; port 443 gets one HTTPS probe;
    # other addresses get nc -z on every TCP port of their Service.
    tcpok=true
    if [ "$ip" != "$ENTRY_IP" ]; then
      if jq -e --arg ip "$ip" '[.[] | select(.got | index($ip)) | .tcp[]] | index(443)' <<<"$svcs" >/dev/null; then
        first=${HOSTS%% *}
        with_retry https_probe "$first.$DOMAIN" "$ip" "lb-$ip" || { tcpok=false; reason 9 "$ip: no HTTPS answer for $first.$DOMAIN"; }
      else
        for port in $(jq -r --arg ip "$ip" '[.[] | select(.got | index($ip)) | .tcp[]] | unique | .[]' <<<"$svcs"); do
          with_retry nc -z -G 3 "$ip" "$port" >/dev/null 2>&1 || { tcpok=false; reason 9 "$ip:$port refused or timed out"; }
        done
      fi
    fi
    d=$(jq -c --arg ip "$ip" --arg s "$s" --arg v "$viphost" --arg h "$holders" --arg seen "$nodeseen" --argjson tcp "$tcpok" \
      '. + [{ip: $ip, service: $s, viphost: $v, holders: $h, arp_nodes: $seen, tcp_ok: $tcp}]' <<<"$d")
  done

  # Public TCP through NAT loopback.
  if [ -n "$WAN" ]; then
    for port in $PUBLIC_TCP; do
      with_retry nc -z -G 3 "$WAN" "$port" >/dev/null 2>&1 || reason 9 "public $port on the WAN address refused or timed out"
    done
  else
    reason 9 "no WAN address, public TCP checks not run"
  fi
  finish_item 9 lb "$(jq -n --argjson b "$d" --argjson s "$svcs" '{services: $s, bindings: $b}')"
}

# --- run --------------------------------------------------------------------------------
item_nodes
item_etcd
item_pods
item_pvcs
item_databases
item_argo
read_wan || true
item_dns
item_http
item_immich
item_lb

FINISHED=$(utc_now)
base=$(prev '.baseline // null')
if [ "$base" = null ]; then
  if [ -n "$PREVIOUS" ]; then
    base=$(jq -c '{from: .started, http: ([.items[] | select(.id == 7) | .detail.hosts][0] // {})}' "$PREVIOUS")
  else
    base=$(jq -c --arg from "$STARTED" '{from: $from, http: .}' "$RES/http.json" 2>/dev/null || echo null)
  fi
fi
jq -s --arg started "$STARTED" --arg finished "$FINISHED" --arg entry "$ENTRY_IP" \
  --arg previous "${PREVIOUS:+$(basename "$PREVIOUS")}" --argjson baseline "$base" \
  --rawfile info "$RES/info.txt" --rawfile hard "$RES/hard.txt" '
  {schema: 1, tool: "scripts/smoke.sh", started: $started, finished: $finished, entry_ip: $entry,
   previous: (if $previous == "" then null else $previous end),
   green: (all(.[]; .pass)),
   failed_items: [.[] | select(.pass | not) | .id],
   hard_stop_signals: ($hard | split("\n") | map(select(. != "")) | unique),
   info: ($info | split("\n") | map(select(. != ""))),
   baseline: $baseline,
   items: (sort_by(.id))}' "$RES"/item-*.json > "$RES/out.json" || { echo "smoke: cannot assemble the JSON" >&2; exit 1; }
cat "$RES/out.json"
if jq -e '.green' "$RES/out.json" >/dev/null; then exit 0; fi
exit 1
