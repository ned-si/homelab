#!/bin/bash
# scripts/status.sh against fake kubectl, talosctl, nc and curl: no cluster,
# no network. The fake kubectl refuses unbounded calls, any verb other than
# get/exec, any exec that is not a read-only psql, any Secret read that could
# return values, and any call it does not know; the fake talosctl answers only
# `get services etcd`. Addresses are from the documentation ranges.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

STATUS="$REPO_ROOT/scripts/status.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
FIX="$tmp/fix"
mkdir -p "$tmp/bin" "$FIX"
export STATUS_FIX="$FIX" STATUS_NOW=1790000000 STATUS_API_VIP=192.0.2.11 STATUS_NAS_HOST=192.0.2.228
export PATH="$tmp/bin:$PATH"

# The address the script must compare against: read from the real values file
# the same way an operator would, so no address literal sits in this test.
GIT_WAN=$(sed -n 's/^[[:space:]]*-[[:space:]]*--default-targets=\([0-9.]*\)[[:space:]]*$/\1/p' \
  "$REPO_ROOT/infrastructure/external-dns/values.yaml" | head -n 1)

cat > "$tmp/bin/kubectl" <<'FAKE'
#!/bin/bash
f=${STATUS_FIX:?}
bounded=0
args=()
for a in "$@"; do
  case "$a" in
    --request-timeout=*) bounded=1 ;;
    *) args+=("$a") ;;
  esac
done
s="${args[*]}"
echo "$s" >> "$f/calls.log"
[ "$bounded" = 1 ] || { echo "fake kubectl: unbounded call: $s" >&2; exit 2; }
verb=""
for a in "${args[@]}"; do
  case "$a" in -n|-A|-l|-c|-o) continue ;; -*) continue ;; esac
  verb=$a; break
done
# `-n <ns>` puts the namespace first; skip it to find the verb.
if [ "${args[0]}" = "-n" ]; then verb=${args[2]}; fi
case "$verb" in get|exec) ;; *) echo "fake kubectl: mutating or unknown verb '$verb'" >&2; exit 3 ;; esac
# STATUS_FAIL_GET=<resource>: that read fails, as with an unreachable API.
for r in ${STATUS_FAIL_GET:-}; do
  case "$s" in "get $r "*) echo "error: the server is currently unable to handle the request" >&2; exit 1 ;; esac
done
case "$s" in
  # First match wins: the jsonpath form is the only Secret read allowed.
  "get secrets -A -o jsonpath="*)
    case "$s" in *.data*|*stringData*) echo "fake kubectl: jsonpath reads data" >&2; exit 3 ;; esac
    cat "$f/secrets.tsv" ;;
  *" secret"*)
    echo "fake kubectl: Secret read that returns values: $s" >&2; exit 3 ;;
  "get nodes -o json") cat "$f/nodes.json" ;;
  "get applications.argoproj.io -n argo -o json") cat "$f/apps.json" ;;
  "get pods -A -o json") cat "$f/pods.json" ;;
  "get pvc -A -o json") cat "$f/pvc.json" ;;
  "get clusters.postgresql.cnpg.io -A -o json") cat "$f/cnpg.json" ;;
  "get certificates.cert-manager.io -A -o json") cat "$f/certs.json" ;;
  "get gateways.gateway.networking.k8s.io -A -o json") cat "$f/gw.json" ;;
  "get httproutes.gateway.networking.k8s.io -A -o json") cat "$f/routes.json" ;;
  "get svc -A -o json") cat "$f/svc.json" ;;
  "get cronjobs -A -o json") cat "$f/cronjobs.json" ;;
  "-n immich get pod -l cnpg.io/cluster=immich-db,role=primary -o name") echo "pod/immich-db-1" ;;
  "-n immich exec immich-db-1 -c postgres -- env PGOPTIONS=-c default_transaction_read_only=on psql -d app -tAc "*)
    # STATUS_NO_EXEC: exec is forbidden, as for the alert-triage ServiceAccount.
    [ -n "${STATUS_NO_EXEC:-}" ] && { echo 'Error from server (Forbidden): pods "immich-db-1" is forbidden: cannot create resource "pods/exec"' >&2; exit 1; }
    printf 'IMAGE|100\nVIDEO|10\n' ;;
  *) echo "fake kubectl: unexpected call: $s" >&2; exit 1 ;;
esac
FAKE
cat > "$tmp/bin/nc" <<'FAKE'
#!/bin/bash
# nc -z -G 3 <host> <port>: closed when "<host>:<port>" is listed in nc-closed.
echo "nc $*" >> "$STATUS_FIX/calls.log"
[ "$1 $2 $3" = "-z -G 3" ] || { echo "fake nc: unexpected flags $*" >&2; exit 2; }
! grep -qxF "$4:$5" "$STATUS_FIX/nc-closed" 2>/dev/null
FAKE
cat > "$tmp/bin/curl" <<'FAKE'
#!/bin/bash
echo "curl $*" >> "$STATUS_FIX/calls.log"
case " $* " in *" -m "*) ;; *) echo "fake curl: unbounded" >&2; exit 2 ;; esac
case "$*" in *api.ipify.org*|*ifconfig.me*) cat "$STATUS_FIX/wan.txt" ;; *) exit 6 ;; esac
FAKE
cat > "$tmp/bin/talosctl" <<'FAKE'
#!/bin/bash
# talosctl -n <ip> get services etcd -o json: healthy unless <ip> is listed
# in etcd-unhealthy.
echo "talosctl $*" >> "$STATUS_FIX/calls.log"
[ "$1" = -n ] && [ "${*:3}" = "get services etcd -o json" ] || { echo "fake talosctl: unexpected call: $*" >&2; exit 1; }
[ -n "${STATUS_TALOS_FAIL:-}" ] && { echo "error constructing client: talos config file is empty" >&2; exit 1; }
h=true
grep -qxF "$2" "$STATUS_FIX/etcd-unhealthy" 2>/dev/null && h=false
echo "{\"metadata\":{\"id\":\"etcd\"},\"spec\":{\"healthy\":$h,\"running\":true}}"
FAKE
chmod +x "$tmp/bin/kubectl" "$tmp/bin/talosctl" "$tmp/bin/nc" "$tmp/bin/curl"

# mkfix: a healthy cluster.
mkfix() {
  : > "$FIX/calls.log"
  : > "$FIX/nc-closed"
  : > "$FIX/etcd-unhealthy"
  echo "$GIT_WAN" > "$FIX/wan.txt"
  cat > "$FIX/nodes.json" <<'EOF'
{"items":[
 {"metadata":{"name":"cp-1","labels":{"node-role.kubernetes.io/control-plane":""}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"kubeletVersion":"v1.37.1","kernelVersion":"6.18.31-talos","osImage":"Talos (v1.14.2)","containerRuntimeVersion":"containerd://2.2.4"},"addresses":[{"type":"InternalIP","address":"192.0.2.247"}]}},
 {"metadata":{"name":"cp-2","labels":{"node-role.kubernetes.io/control-plane":""}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"kubeletVersion":"v1.37.1","kernelVersion":"6.18.31-talos","osImage":"Talos (v1.14.2)","containerRuntimeVersion":"containerd://2.2.4"},"addresses":[{"type":"InternalIP","address":"192.0.2.238"}]}},
 {"metadata":{"name":"cp-3","labels":{"node-role.kubernetes.io/control-plane":""}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"kubeletVersion":"v1.37.1","kernelVersion":"6.18.31-talos","osImage":"Talos (v1.14.2)","containerRuntimeVersion":"containerd://2.2.4"},"addresses":[{"type":"InternalIP","address":"192.0.2.239"}]}},
 {"metadata":{"name":"w-1"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"kubeletVersion":"v1.37.1","kernelVersion":"6.18.31-talos","osImage":"Talos (v1.14.2)","containerRuntimeVersion":"containerd://2.2.4"},"addresses":[{"type":"InternalIP","address":"192.0.2.240"}]}}]}
EOF
  cat > "$FIX/apps.json" <<'EOF'
{"items":[
 {"metadata":{"name":"root"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
 {"metadata":{"name":"immich"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}]}
EOF
  cat > "$FIX/pods.json" <<'EOF'
{"items":[
 {"metadata":{"namespace":"immich","name":"immich-server-1"},"status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":3,"state":{"running":{}}}]}},
 {"metadata":{"namespace":"mealie","name":"mealie-backup-1"},"status":{"phase":"Succeeded","containerStatuses":[{"ready":false,"restartCount":0,"state":{"terminated":{}}}]}}]}
EOF
  echo '{"items":[{"metadata":{"namespace":"immich","name":"immich-data"},"status":{"phase":"Bound"}}]}' > "$FIX/pvc.json"
  echo '{"items":[{"metadata":{"namespace":"immich","name":"immich-db"},"spec":{"instances":1},"status":{"phase":"Cluster in healthy state","readyInstances":1}}]}' > "$FIX/cnpg.json"
  # STATUS_NOW is 2026-09-21T14:13:20Z.
  echo '{"items":[{"metadata":{"namespace":"gateway","name":"wildcard"},"status":{"notAfter":"2026-11-20T00:00:00Z","conditions":[{"type":"Ready","status":"True"}]}}]}' > "$FIX/certs.json"
  echo '{"items":[{"metadata":{"namespace":"gateway","name":"shared"},"status":{"addresses":[{"value":"192.0.2.254"}],"conditions":[{"type":"Programmed","status":"True"}]}}]}' > "$FIX/gw.json"
  echo '{"items":[{"metadata":{"namespace":"immich","name":"immich"},"spec":{"hostnames":["media.example.test"]},"status":{"parents":[{"conditions":[{"type":"Accepted","status":"True"}]}]}}]}' > "$FIX/routes.json"
  echo '{"items":[{"metadata":{"namespace":"syncthing","name":"syncthing-protocol"},"spec":{"type":"LoadBalancer"},"status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.201"}]}}},{"metadata":{"namespace":"default","name":"kubernetes"},"spec":{"type":"ClusterIP"},"status":{}}]}' > "$FIX/svc.json"
  cat > "$FIX/cronjobs.json" <<'EOF'
{"items":[
 {"metadata":{"namespace":"mealie","name":"mealie-backup"},"spec":{"suspend":false},"status":{"lastSuccessfulTime":"2026-09-21T02:00:00Z","lastScheduleTime":"2026-09-21T02:00:00Z"}},
 {"metadata":{"namespace":"theater","name":"recyclarr-sync"},"spec":{},"status":{}}]}
EOF
  printf 'immich\timmich-config\tOpaque\t2026-09-01T00:00:00Z\nimmich\timmich-db-app\tkubernetes.io/basic-auth\t2026-01-01T00:00:00Z\n' > "$FIX/secrets.tsv"
}

echo "healthy cluster"
mkfix
rc=0; out=$("$STATUS" 2>&1) || rc=$?
expect_eq "exit 0" 0 "$rc"
expect_contains "no problems" "no problems" "$out"
expect_contains "node line" "cp-1  Ready  192.0.2.247  v1.37.1  6.18.31-talos  containerd://2.2.4" "$out"
expect_contains "etcd" "etcd 3/3 healthy" "$out"
expect_contains "VIP" "API VIP 192.0.2.11:6443 reachable" "$out"
expect_contains "argo" "2 Applications Synced/Healthy" "$out"
expect_contains "pods: Completed counts as fine" "2 pods, all Running or Completed" "$out"
expect_contains "restarts listed" "restarts 3  immich/immich-server-1" "$out"
expect_contains "PVCs" "PVCs 1/1 Bound" "$out"
expect_contains "CNPG" "CNPG 1 clusters healthy" "$out"
expect_contains "cert days" "gateway/wildcard  59d" "$out"
expect_contains "route" "1 HTTPRoutes Accepted: media" "$out"
expect_contains "LB" "LB 192.0.2.201  syncthing/syncthing-protocol" "$out"
expect_contains "backup age" "1 backup CronJobs, oldest last success 12h ago" "$out"
expect_contains "NAS" "NAS 192.0.2.228:3260 open" "$out"
expect_contains "WAN matches" "= --default-targets in infrastructure/external-dns/values.yaml" "$out"
expect_contains "Immich counts" "Immich  image 100  video 10" "$out"
expect_contains "secrets summary" "2 Secrets in 1 namespaces" "$out"
expect_contains "oldest Secret by name and age" "263d  immich/immich-db-app" "$out"
case "$out" in *$'\033['*) bad "no colour when not a terminal" ;; *) ok "no colour when not a terminal" ;; esac
case "$out" in *recyclarr*) bad "non-backup CronJobs are not listed" ;; *) ok "non-backup CronJobs are not listed" ;; esac

echo "--json"
rc=0; js=$("$STATUS" --json 2>/dev/null) || rc=$?
expect_eq "exit 0" 0 "$rc"
expect_eq "schema" 1 "$(jq -r .schema <<<"$js")"
expect_eq "no problems" 0 "$(jq '.problems | length' <<<"$js")"
expect_eq "immich images" 100 "$(jq .immich.image <<<"$js")"
expect_eq "wan match" true "$(jq .wan.match <<<"$js")"
expect_eq "wan in git" "$GIT_WAN" "$(jq -r .wan.in_git <<<"$js")"
expect_eq "no failed reads" 0 "$(jq '.errors | length' <<<"$js")"
expect_eq "every section present" "argo,backups,certificates,cnpg,errors,etcd,gateway,generated,immich,nas,nodes,pods,problems,pvcs,schema,secrets,wan" \
  "$(jq -r 'keys | join(",")' <<<"$js")"

echo "read-only"
calls=$(cat "$FIX/calls.log")
expect_contains "Secrets read through jsonpath" "get secrets -A -o jsonpath=" "$calls"
case "$calls" in *" data"*|*".data"*) bad "never asks for Secret data" ;; *) ok "never asks for Secret data" ;; esac
expect_contains "psql is read-only" "PGOPTIONS=-c default_transaction_read_only=on psql" "$calls"

echo "broken cluster"
mkfix
jq '.items[3].status.conditions[0].status = "False"' "$FIX/nodes.json" > "$FIX/x" && mv "$FIX/x" "$FIX/nodes.json"
echo 192.0.2.238 > "$FIX/etcd-unhealthy"
jq '.items[1].status.sync.status = "OutOfSync"' "$FIX/apps.json" > "$FIX/x" && mv "$FIX/x" "$FIX/apps.json"
jq '.items[0].status.containerStatuses[0] += {ready: false, state: {waiting: {reason: "CrashLoopBackOff"}}}' "$FIX/pods.json" > "$FIX/x" && mv "$FIX/x" "$FIX/pods.json"
echo '{"items":[{"metadata":{"namespace":"paperless","name":"paperless-data"},"status":{"phase":"Pending"}}]}' > "$FIX/pvc.json"
echo '{"items":[{"metadata":{"namespace":"gateway","name":"wildcard"},"status":{"notAfter":"2026-09-26T00:00:00Z","conditions":[{"type":"Ready","status":"True"}]}}]}' > "$FIX/certs.json"
jq '.items[0].status.lastSuccessfulTime = "2026-09-19T02:00:00Z"' "$FIX/cronjobs.json" > "$FIX/x" && mv "$FIX/x" "$FIX/cronjobs.json"
echo "192.0.2.228:2049" > "$FIX/nc-closed"
echo "198.51.100.99" > "$FIX/wan.txt"
rc=0; out=$("$STATUS" 2>&1) || rc=$?
expect_eq "exit 1" 1 "$rc"
expect_contains "node" "w-1  NotReady" "$out"
expect_contains "etcd" "etcd 2/3 healthy" "$out"
expect_contains "argo" "immich  OutOfSync/Healthy" "$out"
expect_contains "pod" "immich/immich-server-1  Running CrashLoopBackOff  restarts=3" "$out"
expect_contains "pvc" "paperless/paperless-data Pending" "$out"
expect_contains "cert" "gateway/wildcard  4d" "$out"
expect_contains "backup" "mealie/mealie-backup  last success 60h ago" "$out"
expect_contains "nas" "NAS 192.0.2.228:2049 CLOSED" "$out"
expect_contains "wan" "WAN 198.51.100.99 != --default-targets $GIT_WAN" "$out"
js=$("$STATUS" --json 2>/dev/null) || true
expect_eq "nine problems" 9 "$(jq '.problems | length' <<<"$js")"

echo "failed reads"
mkfix
rc=0; out=$(STATUS_FAIL_GET="applications.argoproj.io pods secrets" "$STATUS" 2>&1) || rc=$?
expect_eq "exit 1" 1 "$rc"
expect_contains "section" "Reads that failed" "$out"
expect_contains "argo read" "kubectl get applications.argoproj.io -n argo failed: error: the server is currently unable" "$out"
expect_contains "pods read" "kubectl get pods -A failed" "$out"
expect_contains "secrets read" "kubectl get secrets -A failed" "$out"
js=$(STATUS_FAIL_GET="applications.argoproj.io pods secrets" "$STATUS" --json 2>/dev/null) || true
expect_eq "three problems, all reads" 3 "$(jq '[.problems[] | select(test("^kubectl get .* failed"))] | length' <<<"$js")"
expect_eq "nothing else" 3 "$(jq '.problems | length' <<<"$js")"

echo "usage"
rc=0; "$STATUS" --bogus >/dev/null 2>&1 || rc=$?
expect_eq "unknown flag exits 64" 64 "$rc"

echo "talosctl cannot reach any node"
mkfix
rc=0; out=$(STATUS_TALOS_FAIL=1 "$STATUS" 2>&1) || rc=$?
expect_eq "exit 1" 1 "$rc"
expect_contains "etcd unreadable, not 0/3" "etcd health unreadable (talosctl: no node answered" "$out"
case "$out" in *"etcd 0/"*) bad "no 0/N count" ;; *) ok "no 0/N count" ;; esac


echo "exec forbidden (the alert-triage ServiceAccount)"
mkfix
rc=0; out=$(STATUS_NO_EXEC=1 "$STATUS" --no-color 2>&1) || rc=$?
expect_eq "a forbidden exec is not a problem" 0 "$rc"
expect_contains "counts say why" "Immich counts unavailable (no exec)" "$out"

finish
