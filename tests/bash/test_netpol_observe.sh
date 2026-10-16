#!/bin/bash
# Tests for scripts/netpol-observe.sh with a fake `hubble` and a fake `curl`.
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/netpol-observe.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Fake hubble: prints the fixture, logs its arguments.
cat > "$tmp/hubble" <<'FAKE'
#!/bin/bash
echo "$*" > "$FAKE_DIR/hubble.args"
cat "$FAKE_DIR/flows.json"
FAKE
chmod +x "$tmp/hubble"

# Fake curl: prints the Prometheus response, logs its arguments.
cat > "$tmp/curl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_DIR/curl.args"
cat "$FAKE_DIR/prom.json"
FAKE
chmod +x "$tmp/curl"

export FAKE_DIR="$tmp" HUBBLE="$tmp/hubble" CURL="$tmp/curl"

# Two connections from the Gateway to mealie:9000 (covered, l3-l4), one egress
# to the internet on 443 not covered by any rule (match 4 = all), one egress to
# the API server (l3-only), and one verdict of another namespace's policy that
# names mealie as the destination (must be ignored).
cat > "$tmp/flows.json" <<'EOF'
{"flow":{"time":"2026-10-16T10:00:00Z","traffic_direction":"INGRESS","policy_match_type":2,"IP":{"source":"10.244.1.5","destination":"10.244.2.7"},"l4":{"TCP":{"destination_port":9000}},"source":{"labels":["reserved:ingress"]},"destination":{"namespace":"mealie","workloads":[{"name":"mealie","kind":"Deployment"}]}}}
{"flow":{"time":"2026-10-16T10:05:00Z","traffic_direction":"INGRESS","policy_match_type":2,"IP":{"source":"10.244.1.5","destination":"10.244.2.7"},"l4":{"TCP":{"destination_port":9000}},"source":{"labels":["reserved:ingress"]},"destination":{"namespace":"mealie","workloads":[{"name":"mealie","kind":"Deployment"}]}}}
{"flow":{"time":"2026-10-16T10:02:00Z","traffic_direction":"EGRESS","policy_match_type":4,"IP":{"source":"10.244.2.7","destination":"203.0.113.10"},"l4":{"TCP":{"destination_port":443}},"source":{"namespace":"mealie","labels":["k8s:app.kubernetes.io/name=mealie"]},"destination":{"labels":["reserved:world"]}}}
{"flow":{"time":"2026-10-16T10:03:00Z","traffic_direction":"EGRESS","policy_match_type":1,"IP":{"source":"10.244.2.8","destination":"192.168.1.11"},"l4":{"TCP":{"destination_port":6443}},"source":{"namespace":"mealie","pod_name":"mealie-postgresql-1"},"destination":{"labels":["reserved:kube-apiserver"]}}}
{"flow":{"time":"2026-10-16T10:04:00Z","traffic_direction":"EGRESS","policy_match_type":4,"IP":{"source":"10.244.3.1","destination":"10.244.2.7"},"l4":{"TCP":{"destination_port":9000}},"source":{"namespace":"theater","workloads":[{"name":"sonarr"}]},"destination":{"namespace":"mealie"}}}
EOF

out=$(bash "$SCRIPT" mealie --since 2h)
expect_contains "hubble asked for policy verdicts of the namespace" \
  "--namespace mealie --type policy-verdict --since 2h" "$(cat "$tmp/hubble.args")"
expect_eq "header plus three groups" 4 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
expect_eq "Gateway ingress grouped, sorted first" \
  "$(printf 'ingress\tingress\t9000\tTCP\tl3-l4\t2\t2026-10-16T10:00:00Z\t2026-10-16T10:05:00Z')" \
  "$(printf '%s\n' "$out" | sed -n 2p)"
expect_contains "uncovered egress to the internet shows match all" \
  "$(printf 'egress\tworld:203.0.113.10\t443\tTCP\tall\t1')" "$out"
expect_contains "API server egress, peer from the reserved identity, pod name as fallback" \
  "$(printf 'egress\tkube-apiserver\t6443\tTCP\tl3-only\t1')" "$out"
case "$out" in
  *theater*) bad "another namespace's verdict is ignored" ;;
  *) ok "another namespace's verdict is ignored" ;;
esac

cat > "$tmp/prom.json" <<'EOF'
{"status":"success","data":{"resultType":"vector","result":[
{"metric":{"direction":"egress","match":"all","source":"mealie","source_namespace":"mealie","destination":"world","destination_namespace":""},"value":[1760000000,"3.2"]},
{"metric":{"direction":"ingress","match":"l3-l4","source":"ingress","source_namespace":"","destination":"mealie","destination_namespace":"mealie"},"value":[1760000000,"120.0"]}
]}}
EOF
out=$(bash "$SCRIPT" mealie --days 7 --prom http://prom.test:9090)
expect_contains "query covers 7 days" "[7d]" "$(cat "$tmp/curl.args")"
expect_contains "query targets the Prometheus URL" "http://prom.test:9090/api/v1/query" "$(cat "$tmp/curl.args")"
expect_eq "history sorted by count" "$(printf 'ingress\tingress\tl3-l4\t120')" "$(printf '%s\n' "$out" | sed -n 2p)"
expect_contains "history egress peer is the destination" "$(printf 'egress\tworld\tall\t3')" "$out"

if bash "$SCRIPT" 'Bad_NS' >/dev/null 2>&1; then bad "rejects an invalid namespace"; else ok "rejects an invalid namespace"; fi
if bash "$SCRIPT" mealie --days x >/dev/null 2>&1; then bad "rejects a non-numeric --days"; else ok "rejects a non-numeric --days"; fi

finish
