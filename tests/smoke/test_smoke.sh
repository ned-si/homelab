#!/bin/bash
# scripts/smoke.sh against fake kubectl, talosctl, curl, dig, nc, ping, arp
# and openssl (tests/smoke/fakebin): no cluster, no network. The fakes refuse
# unbounded calls and any call they do not know, so a new or mutating command
# in smoke.sh fails these tests. Addresses are from the documentation ranges.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/../bash/lib.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE="$REPO_ROOT/scripts/smoke.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$HERE/fakebin:$PATH"
export SMOKE_RETRY_SLEEP=0 SMOKE_ARP_INTERVAL=0 SMOKE_ARP_SAMPLES=2
export SMOKE_DOMAIN=example.test SMOKE_HOSTS="argo media" SMOKE_API_VIP=192.0.2.11
export SMOKE_PVC_MIN=3 SMOKE_CNPG_MIN=2 SMOKE_NOW=1790000000
export SMOKE_SSO_APPS="argo /auth/login argocd /auth/callback"
WAN=198.51.100.7
ENTRY=192.0.2.254
KC=https://auth.example.test/realms/homelab
KC_AUTH="$KC/protocol/openid-connect/auth?client_id=argocd&redirect_uri=https%3A%2F%2Fargo.example.test%2Fauth%2Fcallback&response_type=code&state=s1"
CS=fixture-client-secret

# addr <dir> <node-ip> <cidr> [family]: one address resource, as
# `talosctl get addresses -o json` prints it (one JSON document per line).
addr() {
  jq -cn --arg a "$3" --arg f "${4:-inet4}" '{spec: {address: $a, family: $f}}' >> "$1/talos/$2-addresses.json"
}

# mkfix <dir>: a healthy cluster.
mkfix() {
  local d=$1 n ip
  mkdir -p "$d/talos"
  : > "$d/calls.log"
  echo "$WAN" > "$d/wan.txt"
  cat > "$d/nodes.json" <<'EOF'
{"items":[
 {"metadata":{"name":"cp-1","labels":{"node-role.kubernetes.io/control-plane":""}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"kubeletVersion":"v1.37.1","osImage":"Talos (v1.14.2)"},"addresses":[{"type":"InternalIP","address":"192.0.2.247"}]}},
 {"metadata":{"name":"cp-2","labels":{"node-role.kubernetes.io/control-plane":""}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"kubeletVersion":"v1.37.1","osImage":"Talos (v1.14.2)"},"addresses":[{"type":"InternalIP","address":"192.0.2.238"}]}},
 {"metadata":{"name":"cp-3","labels":{"node-role.kubernetes.io/control-plane":""}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"kubeletVersion":"v1.37.1","osImage":"Talos (v1.14.2)"},"addresses":[{"type":"InternalIP","address":"192.0.2.239"}]}},
 {"metadata":{"name":"w-1"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"kubeletVersion":"v1.37.1","osImage":"Talos (v1.14.2)"},"addresses":[{"type":"InternalIP","address":"192.0.2.240"}]}}]}
EOF
  printf 'cp-1 aa:bb:cc:00:00:01\ncp-2 AA:BB:CC:00:00:02\ncp-3 aa:bb:cc:00:00:03\nw-1 aa:bb:cc:00:00:04\n' > "$d/node-macs.txt"
  for ip in 192.0.2.247 192.0.2.238 192.0.2.239; do
    echo '{"metadata":{"id":"etcd"},"spec":{"healthy":true,"running":true}}' > "$d/talos/$ip-etcd.json"
  done
  cat > "$d/pods.json" <<'EOF'
{"items":[
 {"metadata":{"namespace":"immich","name":"immich-server-1","creationTimestamp":"2026-01-01T00:00:00Z"},"status":{"phase":"Running","containerStatuses":[{"state":{"running":{}}}]}},
 {"metadata":{"namespace":"argo","name":"argocd-server-1","creationTimestamp":"2026-01-01T00:00:00Z"},"status":{"phase":"Running","initContainerStatuses":[{"state":{"terminated":{}}}],"containerStatuses":[{"state":{"running":{}}}]}}]}
EOF
  cat > "$d/pvc.json" <<'EOF'
{"items":[
 {"metadata":{"namespace":"immich","name":"immich-data"},"status":{"phase":"Bound"}},
 {"metadata":{"namespace":"theater","name":"plex-config"},"status":{"phase":"Bound"}},
 {"metadata":{"namespace":"seafile","name":"mariadb"},"status":{"phase":"Bound"}}]}
EOF
  cat > "$d/cnpg.json" <<'EOF'
{"items":[
 {"metadata":{"namespace":"immich","name":"immich-db"},"status":{"phase":"Cluster in healthy state"}},
 {"metadata":{"namespace":"keycloak","name":"keycloak-db"},"status":{"phase":"Cluster in healthy state"}}]}
EOF
  cat > "$d/apps.json" <<'EOF'
{"items":[
 {"metadata":{"name":"all-apps"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
 {"metadata":{"name":"cert-manager"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
 {"metadata":{"name":"cnpg"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"},"conditions":[{"type":"SharedResourceWarning"}]}}]}
EOF
  printf '# the gated set\nall-apps sync+health\ncert-manager sync+health\n\ncnpg sync+health\n' > "$d/gate.txt"
  echo "pod/immich-db-1" > "$d/immich-primary.txt"
  cat > "$d/immich-sql.txt" <<'EOF'
Q1: SELECT type, count(*) FROM asset GROUP BY type ORDER BY 1
Q2: SELECT type, count(*) FROM asset WHERE "deletedAt" IS NULL GROUP BY type ORDER BY 1
Q3: SELECT count(*) FROM asset_audit WHERE "deletedAt" > '<previous run UTC>'
ORIG: SELECT "originalPath" FROM asset WHERE "deletedAt" IS NULL AND NOT "isOffline" ORDER BY random() LIMIT 20
EOF
  printf 'IMAGE|100\nVIDEO|10\n' > "$d/q1.txt"
  printf 'IMAGE|98\nVIDEO|10\n' > "$d/q2.txt"
  echo 0 > "$d/q3.txt"
  printf '/data/library/a.jpg\n/data/library/b.mp4\n' > "$d/orig.txt"
  cat > "$d/svc.json" <<'EOF'
{"items":[
 {"metadata":{"namespace":"gateway","name":"cilium-gateway-shared"},
  "spec":{"type":"LoadBalancer","ports":[{"port":80,"protocol":"TCP"},{"port":443,"protocol":"TCP"}]},
  "status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.254"}]}}},
 {"metadata":{"namespace":"syncthing","name":"syncthing-protocol","annotations":{"lbipam.cilium.io/ips":"192.0.2.201"}},
  "spec":{"type":"LoadBalancer","ports":[{"port":22000,"protocol":"TCP"},{"port":22000,"protocol":"UDP"}]},
  "status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.201"}]}}},
 {"metadata":{"namespace":"theater","name":"qbittorrent-seed","annotations":{"lbipam.cilium.io/ips":"192.0.2.200"}},
  "spec":{"type":"LoadBalancer","ports":[{"port":50000,"protocol":"TCP"}]},
  "status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.200"}]}}},
 {"metadata":{"namespace":"default","name":"kubernetes"},"spec":{"type":"ClusterIP"},"status":{}}]}
EOF
  for n in 247 238 239 240; do
    ip=192.0.2.$n
    addr "$d" "$ip" 127.0.0.1/8
    addr "$d" "$ip" "$ip/24"
    addr "$d" "$ip" fe80::1/64 inet6
  done
  addr "$d" 192.0.2.238 192.0.2.254/32
  addr "$d" 192.0.2.238 192.0.2.11/32
  printf '192.0.2.254 aa:bb:cc:0:0:2\n192.0.2.201 aa:bb:cc:0:0:4\n192.0.2.200 aa:bb:cc:0:0:1\n' > "$d/arp.txt"
  printf '192.0.2.11:6443\n192.0.2.201:22000\n192.0.2.200:50000\n%s:22000\n%s:443\n' "$WAN" "$WAN" > "$d/nc-open.txt"
  printf 'argo.example.test %s\nmedia.example.test %s\n' "$WAN" "$WAN" > "$d/dig.txt"
  cat > "$d/curl.tsv" <<EOF
https://argo.example.test/ $ENTRY 200 - VALID
https://media.example.test/ $ENTRY 302 https://auth.example.test/login VALID
http://argo.example.test/ $ENTRY 308 https://argo.example.test/ -
http://media.example.test/ $ENTRY 308 https://media.example.test/ -
https://argo.example.test/ $WAN 200 - VALID
https://media.example.test/ $WAN 302 https://auth.example.test/login VALID
https://api.ipify.org - $WAN - -
https://ifconfig.me - $WAN - -
https://argo.example.test/auth/login - 303 $KC_AUTH -
$KC_AUTH - 200 - -
$KC/protocol/openid-connect/token secret:$CS 400 - -
$KC/protocol/openid-connect/token secret:* 401 - -
EOF
  jq -n --arg iss "$KC" '{data: {"oidc.config": ("name: Keycloak\nissuer: " + $iss + "\nclientID: argocd\nclientSecret: $argocd-oidc-keycloak:clientSecret\n")}}' > "$d/argocd-cm.json"
  jq -n --arg v "$(printf '%s' "$CS" | base64)" \
    '{metadata: {name: "argocd-oidc-keycloak", labels: {"app.kubernetes.io/part-of": "argocd"}}, data: {clientSecret: $v}}' \
    > "$d/secret-argocd-oidc-keycloak.json"
  jq -n '{metadata: {name: "argocd-secret"}, data: {"server.secretkey": "eA=="}}' > "$d/secret-argocd-secret.json"
}
# tsv_set <file> <url> <field 2> <code> [location]: replace that curl.tsv line.
tsv_set() {
  awk -v u="$2" -v ip="$3" -v c="$4" -v l="${5:--}" '$1 == u && $2 == ip { $3 = c; $4 = l } { print }' "$1/curl.tsv" > "$1/x"
  mv "$1/x" "$1/curl.tsv"
}

# run <fixdir> [args...]: sets RC and OUT (the JSON on stdout).
run() {
  export SMOKE_FIX=$1
  shift
  set +e
  OUT=$(bash "$SMOKE" --node-macs "$SMOKE_FIX/node-macs.txt" --immich-sql "$SMOKE_FIX/immich-sql.txt" \
    --argo-gate "$SMOKE_FIX/gate.txt" --entry-ip "$ENTRY" "$@" 2>"$SMOKE_FIX/stderr.txt")
  RC=$?
  set -e
}
pass_of() { jq -r --argjson id "$1" '.items[] | select(.id == $id) | .pass' <<<"$OUT"; }
fails_of() { jq -r --argjson id "$1" '[.items[] | select(.id == $id) | .failures[]] | join(" | ")' <<<"$OUT"; }
jset() { local t; t=$(jq -c "$2" "$1") && printf '%s\n' "$t" > "$1"; }
fresh() { rm -rf "${tmp:?}/$1"; mkfix "$tmp/$1"; echo "$tmp/$1"; }
# only_failed <ids>: exactly these items failed (no collateral failure).
only_failed() { expect_eq "only item(s) $* fail" "$*" "$(jq -r '.failed_items | map(tostring) | join(" ")' <<<"$OUT")"; }

echo "-- healthy cluster, first run (the baseline)"
F=$(fresh base)
run "$F"
expect_eq "exit 0" 0 "$RC"
expect_eq "green" true "$(jq -r .green <<<"$OUT")"
expect_eq "eleven items, all pass" "1 2 3 4 5 6 7 8 9 10 11" "$(jq -r '[.items[] | select(.pass) | .id] | map(tostring) | join(" ")' <<<"$OUT")"
expect_eq "baseline is this run" "$(jq -r .started <<<"$OUT")" "$(jq -r .baseline.from <<<"$OUT")"
expect_eq "baseline holds both hosts" 2 "$(jq '.baseline.http | length' <<<"$OUT")"
expect_eq "Immich Q1 recorded" '{"IMAGE":100,"VIDEO":10}' "$(jq -c '.items[] | select(.id == 8) | .detail.q1' <<<"$OUT")"
expect_eq "original paths reached the pod on stdin" 2 "$(cat "$F/orig-stdin-lines")"
case "$OUT" in */data/library/*) bad "original paths absent from the JSON" ;; *) ok "original paths absent from the JSON" ;; esac
case "$OUT" in *aa:bb:cc*) bad "no MAC in the JSON" ;; *) ok "no MAC in the JSON" ;; esac
expect_eq "three psql calls (Q1, Q2, ORIG; Q3 only after a decrease)" 3 "$(grep -c ' psql ' "$F/calls.log")"
expect_eq "every psql call is read-only" 0 "$(grep ' psql ' "$F/calls.log" | grep -vc 'PGOPTIONS=-c default_transaction_read_only=on' || true)"
expect_eq "one etcd service read per control-plane node" 3 "$(grep -c '^talosctl -n 192\.0\.2\.2[0-9]* get services etcd -o json$' "$F/calls.log")"
expect_eq "one address read per node" 4 "$(grep -c '^talosctl -n 192\.0\.2\.2[0-9]* get addresses -o json$' "$F/calls.log")"
expect_eq "only read-only talosctl calls" 0 "$(grep '^talosctl ' "$F/calls.log" | grep -vc ' get ' || true)"
expect_eq ".200/.201 on no interface, .254 on cp-2, IPv6 ignored" "||cp-2" \
  "$(jq -r '[.items[] | select(.id == 9) | .detail.bindings[] | .holders] | join("|")' <<<"$OUT")"
expect_contains "Cilium-L2-only address logged INFO" "192.0.2.200 is on no node interface" "$(jq -r '.info | join("\n")' <<<"$OUT")"
expect_eq "a non-error condition does not fail item 6" true "$(pass_of 6)"
printf '%s\n' "$OUT" > "$tmp/base.json"

echo "-- second run with --previous carries the baseline forward"
run "$F" --previous "$tmp/base.json"
expect_eq "green" true "$(jq -r .green <<<"$OUT")"
expect_eq "baseline from the first run" "$(jq -r .started "$tmp/base.json")" "$(jq -r .baseline.from <<<"$OUT")"
expect_eq "previous recorded" base.json "$(jq -r .previous <<<"$OUT")"
printf '%s\n' "$OUT" > "$tmp/second.json"
run "$F" --previous "$tmp/second.json"
expect_eq "third run keeps the first baseline" "$(jq -r .started "$tmp/base.json")" "$(jq -r .baseline.from <<<"$OUT")"

echo "-- item 8: Immich"
F=$(fresh immich1); printf 'IMAGE|95\nVIDEO|10\n' > "$F/q1.txt"; echo 5 > "$F/q3.txt"
run "$F" --previous "$tmp/base.json"
expect_eq "decrease explained by asset_audit passes" true "$(pass_of 8)"
expect_contains "explained decrease is INFO" "explained by 5 asset_audit rows" "$(jq -r '.info | join("\n")' <<<"$OUT")"
expect_contains "Q3 used the previous run's time" "$(jq -r .finished "$tmp/base.json")" "$(grep asset_audit "$F/sql.log")"
F=$(fresh immich2); printf 'IMAGE|95\nVIDEO|10\n' > "$F/q1.txt"; echo 2 > "$F/q3.txt"
run "$F" --previous "$tmp/base.json"
expect_eq "unexplained decrease fails" false "$(pass_of 8)"
expect_eq "exit 1" 1 "$RC"
expect_contains "unexplained decrease is a hard-stop signal" "unexplained Immich asset decrease" "$(jq -r '.hard_stop_signals | join(",")' <<<"$OUT")"
F=$(fresh immich3); printf 'IMAGE|101\nVIDEO|9\n' > "$F/q1.txt"; echo 0 > "$F/q3.txt"
run "$F" --previous "$tmp/base.json"
expect_eq "one type down, no audit row: fails" false "$(pass_of 8)"
F=$(fresh immich4); printf '/data/library/a.jpg\n/data/library/missing.jpg\n' > "$F/orig.txt"
run "$F"
expect_eq "missing original fails" false "$(pass_of 8)"
expect_contains "missing original counted, not named" "1 of 2 sampled originals are missing" "$(fails_of 8)"
case "$OUT" in *missing.jpg*) bad "missing path not printed" ;; *) ok "missing path not printed" ;; esac
F=$(fresh immich5); : > "$F/orig.txt"
run "$F"
expect_eq "no originals sampled fails" false "$(pass_of 8)"
F=$(fresh immich6); jq '.finished = "2026-01-01T00:00:00Z'"'"'; DROP TABLE asset; --"' "$tmp/base.json" > "$tmp/evil.json"
printf 'IMAGE|95\nVIDEO|10\n' > "$F/q1.txt"; echo 99 > "$F/q3.txt"
run "$F" --previous "$tmp/evil.json"
expect_eq "malformed previous timestamp: decrease stays unexplained" false "$(pass_of 8)"
expect_eq "malformed timestamp never reaches SQL" 0 "$(grep -c DROP "$F/sql.log" || true)"
F=$(fresh immich7); echo "" > "$F/immich-primary.txt"
run "$F"
expect_eq "no primary pod fails" false "$(pass_of 8)"

echo "-- item 6: Argo gate"
F=$(fresh argo1); echo "nginx sync+health" >> "$F/gate.txt"
run "$F"
expect_eq "listed Application missing fails" false "$(pass_of 6)"
only_failed 6
expect_contains "named in the failure" "gated Application nginx does not exist" "$(fails_of 6)"
F=$(fresh argo2)
jset "$F/apps.json" '.items += [{"metadata":{"name":"gateway"},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Missing"}}}]'
run "$F"
expect_eq "unlisted OutOfSync/Missing passes" true "$(pass_of 6)"
expect_contains "and is reported" "Application gateway is OutOfSync/Missing (not gated, reported)" "$(jq -r '.info | join("\n")' <<<"$OUT")"
F=$(fresh argo3)
jset "$F/apps.json" '(.items[] | select(.metadata.name == "cnpg") | .status.sync.status) = "OutOfSync"'
printf 'all-apps sync+health\ncert-manager sync+health\ncnpg health\n' > "$F/gate.txt"
run "$F"
expect_eq "health mode ignores OutOfSync" true "$(pass_of 6)"
printf 'all-apps sync+health\ncert-manager sync+health\ncnpg sync+health\n' > "$F/gate.txt"
run "$F"
expect_eq "sync+health mode fails on OutOfSync" false "$(pass_of 6)"
jset "$F/apps.json" '(.items[] | select(.metadata.name == "cnpg") | .status.health.status) = "Degraded"'
printf 'cnpg health\n' > "$F/gate.txt"
run "$F"
expect_eq "health mode fails on Degraded" false "$(pass_of 6)"
for bad_gate in 'cnpg sync' 'cnpg sync+health extra' 'Cnpg health' 'cnpg' 'cnpg health
cnpg sync+health'; do
  F=$(fresh argo4); printf '%s\n' "$bad_gate" > "$F/gate.txt"
  run "$F"
  expect_eq "malformed gate file fails: $(printf '%s' "$bad_gate" | tr '\n' ';')" false "$(pass_of 6)"
done
F=$(fresh argo5); printf '# nothing\n\n' > "$F/gate.txt"
run "$F"
expect_eq "empty gate file fails" false "$(pass_of 6)"
F=$(fresh argo6)
jset "$F/apps.json" '.items += [{"metadata":{"name":"old-child"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}]'
echo "old-child sync+health" >> "$F/gate.txt"
run "$F"
expect_eq "R6-1 setup: gate names an existing Application" true "$(pass_of 6)"
printf '%s\n' "$OUT" > "$tmp/with-child.json"
jset "$F/apps.json" 'del(.items[] | select(.metadata.name == "old-child"))'
run "$F" --previous "$tmp/with-child.json"
expect_eq "R6-1: gate file naming a deleted Application fails" false "$(pass_of 6)"
expect_contains "R6-1 failure names it" "gated Application old-child does not exist" "$(fails_of 6)"
F=$(fresh argo7)
jset "$F/apps.json" '.items += [{"metadata":{"name":"layer-apps"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"},"conditions":[{"type":"SyncError","message":"x"}]}}]'
run "$F"
expect_eq "error condition on an unlisted Application fails" false "$(pass_of 6)"
expect_eq "gate file digest recorded" "$(jq -r '.items[] | select(.id == 6) | .detail.gate_file_sha256' <<<"$OUT" | grep -Ec '^[0-9a-f]{64}$')" 1

echo "-- item 9: LoadBalancer binding"
F=$(fresh lb1); printf '192.0.2.254 de:ad:be:ef:00:01\n192.0.2.201 aa:bb:cc:0:0:4\n192.0.2.200 aa:bb:cc:0:0:1\n' > "$F/arp.txt"
run "$F"
expect_eq "MAC outside N fails" false "$(pass_of 9)"
expect_contains "named as not a node MAC" "which is not a node MAC" "$(fails_of 9)"
only_failed 9
F=$(fresh lb2); printf '192.0.2.254 aa:bb:cc:0:0:2\n192.0.2.201 incomplete\n192.0.2.200 aa:bb:cc:0:0:1\n' > "$F/arp.txt"
run "$F"
expect_eq "(incomplete) after retries fails" false "$(pass_of 9)"
expect_contains "named as incomplete" "192.0.2.201: no ARP entry" "$(fails_of 9)"
F=$(fresh lb3); printf '192.0.2.254 aa:bb:cc:0:0:2\n192.0.2.201 incomplete,aa:bb:cc:0:0:4\n192.0.2.200 aa:bb:cc:0:0:1\n' > "$F/arp.txt"
run "$F"
expect_eq "one (incomplete) then an answer passes" true "$(pass_of 9)"
F=$(fresh lb4); addr "$F" 192.0.2.240 192.0.2.254/32
run "$F"
expect_eq "two interface holders fail" false "$(pass_of 9)"
expect_contains "named as two holders" "more than one node" "$(fails_of 9)"
F=$(fresh lb6); printf '192.0.2.254 aa:bb:cc:0:0:2,aa:bb:cc:0:0:4\n192.0.2.201 aa:bb:cc:0:0:4\n192.0.2.200 aa:bb:cc:0:0:1\n' > "$F/arp.txt"
run "$F"
expect_eq "ARP answer moving within N passes" true "$(pass_of 9)"
expect_contains "and is INFO" "192.0.2.254 ARP answers moved between nodes: cp-2 w-1" "$(jq -r '.info | join("\n")' <<<"$OUT")"
F=$(fresh lb7); jset "$F/svc.json" '(.items[1].status.loadBalancer.ingress[0].ip) = "192.0.2.205"'
printf '192.0.2.205:22000\n' >> "$F/nc-open.txt"; printf '192.0.2.205 aa:bb:cc:0:0:4\n' >> "$F/arp.txt"
run "$F"
expect_eq "status address != requested address fails" false "$(pass_of 9)"
expect_contains "names both addresses" "requests 192.0.2.201 but has 192.0.2.205" "$(fails_of 9)"
F=$(fresh lb8); grep -v '192.0.2.200:50000' "$F/nc-open.txt" > "$F/x" && mv "$F/x" "$F/nc-open.txt"
run "$F"
expect_eq "closed LB TCP port fails" false "$(pass_of 9)"
F=$(fresh lb9); grep -v "$WAN:22000" "$F/nc-open.txt" > "$F/x" && mv "$F/x" "$F/nc-open.txt"
run "$F"
expect_eq "closed public TCP port fails" false "$(pass_of 9)"
F=$(fresh lb10); grep -v '192.0.2.254' "$F/talos/192.0.2.238-addresses.json" > "$F/x" && mv "$F/x" "$F/talos/192.0.2.238-addresses.json"
addr "$F" 192.0.2.239 192.0.2.254/32
run "$F" --previous "$tmp/base.json"
expect_eq "holder moved to another node passes" true "$(pass_of 9)"
expect_contains "holder move is INFO" "192.0.2.254 interface holder moved: 'cp-2' -> 'cp-3'" "$(jq -r '.info | join("\n")' <<<"$OUT")"
F=$(fresh lb11); rm "$F/talos/192.0.2.240-addresses.json"
run "$F"
expect_eq "Talos API unreachable on one node fails item 9" false "$(pass_of 9)"
only_failed 9
F=$(fresh lb12); jset "$F/svc.json" '.items |= map(select(.metadata.name != "cilium-gateway-shared"))'
run "$F"
expect_eq "entry IP in no Service status fails" false "$(pass_of 9)"

echo "-- items 1-5"
F=$(fresh n1); jset "$F/nodes.json" '.items[3].spec.unschedulable = true'
run "$F"
expect_eq "SchedulingDisabled node fails" false "$(pass_of 1)"
only_failed 1
F=$(fresh n2); jset "$F/nodes.json" '.items[1].status.conditions[0].status = "False"'
run "$F"
expect_eq "NotReady node fails" false "$(pass_of 1)"
F=$(fresh n3); jset "$F/nodes.json" 'del(.items[3])'
run "$F"
expect_eq "missing node fails" false "$(pass_of 1)"
F=$(fresh e1); rm "$F/talos/192.0.2.247-etcd.json"
run "$F"
expect_eq "etcd unreadable on one control plane fails" false "$(pass_of 2)"
F=$(fresh e2); echo '{"spec":{"healthy":false,"running":true}}' > "$F/talos/192.0.2.238-etcd.json"
run "$F"
expect_eq "etcd 2/3 fails" false "$(pass_of 2)"
expect_contains "etcd 2/3 is a hard-stop signal" "etcd quorum" "$(jq -r '.hard_stop_signals | join(",")' <<<"$OUT")"
F=$(fresh e3); grep -v '6443' "$F/nc-open.txt" > "$F/x" && mv "$F/x" "$F/nc-open.txt"
run "$F"
expect_eq "VIP down fails" false "$(pass_of 2)"
F=$(fresh p1); jset "$F/pods.json" '.items[0].status.containerStatuses[0].state = {"waiting":{"reason":"CrashLoopBackOff"}}'
run "$F"
expect_eq "CrashLoopBackOff fails" false "$(pass_of 3)"
F=$(fresh p2); jset "$F/pods.json" '.items[1].status.initContainerStatuses[0].state = {"waiting":{"reason":"ImagePullBackOff"}}'
run "$F"
expect_eq "ImagePullBackOff in an init container fails" false "$(pass_of 3)"
F=$(fresh p3); jset "$F/pods.json" '.items += [{"metadata":{"namespace":"theater","name":"plex-x","creationTimestamp":"2026-09-21T13:00:00Z"},"status":{"phase":"Pending"}}]'
run "$F"
expect_eq "Pending for longer than 5 min fails" false "$(pass_of 3)"
expect_contains "names the pod" "pod theater/plex-x: Pending" "$(fails_of 3)"
only_failed 3
echo 'theater/plex-' > "$F/exclude.txt"
run "$F" --pod-exclude "$F/exclude.txt"
expect_eq "excluded pod passes" true "$(pass_of 3)"
F=$(fresh p4); jset "$F/pods.json" '.items += [{"metadata":{"namespace":"theater","name":"plex-y","creationTimestamp":"2026-09-21T14:12:00Z"},"status":{"phase":"Pending"}}]'
run "$F"
expect_eq "Pending for less than 5 min passes" true "$(pass_of 3)"
F=$(fresh v1); jset "$F/pvc.json" '.items[1].status.phase = "Pending"'
run "$F"
expect_eq "PVC not Bound fails" false "$(pass_of 4)"
expect_contains "PVC not Bound is a hard-stop signal" "a PVC is not Bound" "$(jq -r '.hard_stop_signals | join(",")' <<<"$OUT")"
F=$(fresh v2); jset "$F/pvc.json" '.items += [{"metadata":{"namespace":"x","name":"y"},"status":{"phase":"Bound"}}]'
run "$F"
printf '%s\n' "$OUT" > "$tmp/four.json"
jset "$F/pvc.json" 'del(.items[3])'
run "$F" --previous "$tmp/four.json"
expect_eq "Bound count below the previous run fails" false "$(pass_of 4)"
F=$(fresh d1); jset "$F/cnpg.json" '.items[1].status.phase = "Waiting for the instances to become active"'
run "$F"
expect_eq "unhealthy CNPG cluster fails" false "$(pass_of 5)"
only_failed 5

echo "-- items 7 and 10"
F=$(fresh h1); sed -i.bak "s#^https://argo.example.test/ $ENTRY 200#https://argo.example.test/ $ENTRY 503#" "$F/curl.tsv"
run "$F"
expect_eq "5xx on the first run fails" false "$(pass_of 7)"
F=$(fresh h2); sed -i.bak "s#^https://media.example.test/ $ENTRY 302 https://auth.example.test/login#https://media.example.test/ $ENTRY 302 https://other.example.test/x#" "$F/curl.tsv"
run "$F" --previous "$tmp/base.json"
expect_eq "Location host differs from the baseline: fails" false "$(pass_of 7)"
F=$(fresh h3); sed -i.bak "s#^https://media.example.test/ $ENTRY 302 https://auth.example.test/login#https://media.example.test/ $ENTRY 302 https://auth.example.test/other-path#" "$F/curl.tsv"
sed -i.bak "s#^https://media.example.test/ $WAN 302 https://auth.example.test/login#https://media.example.test/ $WAN 302 https://auth.example.test/other-path#" "$F/curl.tsv"
run "$F" --previous "$tmp/base.json"
expect_eq "only the Location path differs: passes" true "$(pass_of 7)"
F=$(fresh h4); sed -i.bak "s#^http://argo.example.test/ $ENTRY 308 https://argo.example.test/#http://argo.example.test/ $ENTRY 200 -#" "$F/curl.tsv"
run "$F"
expect_eq "http:// without a redirect fails" false "$(pass_of 7)"
F=$(fresh h5); sed -i.bak "s#^https://argo.example.test/ $ENTRY 200 - VALID#https://argo.example.test/ $ENTRY 200 - EXPIRING#" "$F/curl.tsv"
run "$F"
expect_eq "certificate valid < 14 days fails" false "$(pass_of 7)"
expect_contains "names the certificate" "cert_ok=false" "$(fails_of 7)"
only_failed 7
F=$(fresh h6); sed -i.bak "s#^https://argo.example.test/ $WAN 200#https://argo.example.test/ $WAN 404#" "$F/curl.tsv"
run "$F"
expect_eq "public path differs from the entry path fails" false "$(pass_of 7)"
F=$(fresh h7); grep -v "^https://media.example.test/ $ENTRY" "$F/curl.tsv" > "$F/x" && mv "$F/x" "$F/curl.tsv"
run "$F"
expect_eq "timeout on the entry IP fails" false "$(pass_of 7)"
F=$(fresh dns1); printf 'argo.example.test %s\nmedia.example.test 203.0.113.9\n' "$WAN" > "$F/dig.txt"
run "$F"
expect_eq "wrong public answer fails item 10" false "$(pass_of 10)"
F=$(fresh dns2); printf 'argo.example.test 203.0.113.9\nmedia.example.test 203.0.113.9\n' > "$F/dig.txt"
sed -i.bak "s#^https://api.ipify.org - $WAN#https://api.ipify.org - 203.0.113.9#; s#^https://ifconfig.me - $WAN#https://ifconfig.me - 203.0.113.9#" "$F/curl.tsv"
run "$F"
expect_eq "WAN change fails item 10" false "$(pass_of 10)"
expect_contains "and reports both sources" "api.ipify.org and ifconfig.me agree on 203.0.113.9" "$(jq -r '.info | join("\n")' <<<"$OUT")"
F=$(fresh dns3); echo "not-an-ip" > "$F/wan.txt"
run "$F"
expect_eq "unreadable --default-targets fails item 10" false "$(pass_of 10)"

echo "-- item 11: SSO"
F=$(fresh s0)
run "$F"
expect_eq "client secret accepted" accepted "$(jq -r '.items[] | select(.id == 11) | .detail.argocd_client_secret' <<<"$OUT")"
expect_eq "client secret never on argv" 0 "$(grep -c "$CS" "$F/calls.log" || true)"
case "$OUT" in *"$CS"*) bad "client secret absent from the JSON" ;; *) ok "client secret absent from the JSON" ;; esac
F=$(fresh s1); tsv_set "$F" https://argo.example.test/auth/login - 303 "${KC_AUTH/argo.example.test%2Fauth%2Fcallback/argo.example.test%2Fother}"
run "$F"
expect_eq "wrong redirect_uri fails" false "$(pass_of 11)"
expect_contains "named in the failure" "redirect_uri is not https://argo.example.test/auth/callback" "$(fails_of 11)"
only_failed 11
F=$(fresh s2); tsv_set "$F" "$KC_AUTH" - 400
run "$F"
expect_eq "Keycloak refusing the authorization request fails" false "$(pass_of 11)"
expect_contains "with Keycloak's code" "Keycloak answers 400" "$(fails_of 11)"
F=$(fresh s3); tsv_set "$F" https://argo.example.test/auth/login - 200
run "$F"
expect_eq "no redirect to Keycloak fails" false "$(pass_of 11)"
F=$(fresh s4); jset "$F/secret-argocd-oidc-keycloak.json" '.data.clientSecret = ("other" | @base64)'
run "$F"
expect_eq "secret Keycloak rejects fails" false "$(pass_of 11)"
expect_contains "named as rejected" "Keycloak rejects the client secret of argocd" "$(fails_of 11)"
only_failed 11
F=$(fresh s5)
# shellcheck disable=SC2016 # a jq program: the $ is literal
jset "$F/argocd-cm.json" '.data["oidc.config"] |= sub("\\$argocd-oidc-keycloak:clientSecret"; "$oidc.keycloak.clientSecret")'
run "$F"
expect_eq "key missing from argocd-secret fails" false "$(pass_of 11)"
expect_contains "names the Secret and key" "Secret argo/argocd-secret has no key oidc.keycloak.clientSecret" "$(fails_of 11)"
F=$(fresh s6); jset "$F/secret-argocd-oidc-keycloak.json" 'del(.metadata.labels)'
run "$F"
expect_eq "Secret without the part-of label fails" false "$(pass_of 11)"
F=$(fresh s7); rm "$F/secret-argocd-oidc-keycloak.json"
run "$F"
expect_eq "missing Secret fails" false "$(pass_of 11)"
expect_contains "named as missing" "Secret argo/argocd-oidc-keycloak (oidc.config clientSecret) is missing" "$(fails_of 11)"

echo "-- usage and input validation (exit 64, nothing runs)"
F=$(fresh u1)
export SMOKE_FIX=$F
set +e
bash "$SMOKE" --node-macs "$F/node-macs.txt" --immich-sql "$F/immich-sql.txt" --argo-gate "$F/gate.txt" >/dev/null 2>&1; rc=$?
expect_eq "missing --entry-ip -> 64" 64 "$rc"
bash "$SMOKE" --node-macs "$F/node-macs.txt" --immich-sql "$F/immich-sql.txt" --argo-gate "$F/gate.txt" --entry-ip 192.0.2.300 >/dev/null 2>&1; rc=$?
expect_eq "invalid --entry-ip -> 64" 64 "$rc"
echo '{"not":"smoke"}' > "$F/prev.json"
bash "$SMOKE" --node-macs "$F/node-macs.txt" --immich-sql "$F/immich-sql.txt" --argo-gate "$F/gate.txt" --entry-ip "$ENTRY" --previous "$F/prev.json" >/dev/null 2>&1; rc=$?
expect_eq "--previous that is not a smoke JSON -> 64" 64 "$rc"
grep -v '^Q3' "$F/immich-sql.txt" > "$F/sql2.txt"
bash "$SMOKE" --node-macs "$F/node-macs.txt" --immich-sql "$F/sql2.txt" --argo-gate "$F/gate.txt" --entry-ip "$ENTRY" >/dev/null 2>&1; rc=$?
expect_eq "--immich-sql without Q3 -> 64" 64 "$rc"
printf 'cp-1 zz:bb:cc:00:00:01\n' > "$F/macs2.txt"
bash "$SMOKE" --node-macs "$F/macs2.txt" --immich-sql "$F/immich-sql.txt" --argo-gate "$F/gate.txt" --entry-ip "$ENTRY" >/dev/null 2>&1; rc=$?
expect_eq "malformed --node-macs -> 64" 64 "$rc"
set -e
expect_eq "no cluster call before validation passes" 0 "$(grep -c . "$F/calls.log" || true)"

finish
