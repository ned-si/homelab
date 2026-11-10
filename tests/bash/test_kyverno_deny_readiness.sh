#!/bin/bash
# Tests for scripts/kyverno-deny-readiness.sh with a fake `kubectl`.
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/kyverno-deny-readiness.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Fake kubectl: answers the reads the script makes from the fixtures in
# $FAKE_DIR, logs every call, and refuses anything else. `down` in $FAKE_DIR
# makes every call fail as an unreachable API server does.
cat > "$tmp/kubectl" <<'FAKE'
#!/bin/bash
d=${FAKE_DIR:?}
args=" $* "
echo "$*" >> "$d/calls.log"
if [ -e "$d/down" ]; then
  echo 'Unable to connect to the server: dial tcp 192.168.1.10:6443: i/o timeout' >&2
  exit 1
fi
case "$args" in
  *" get validatingpolicies.policies.kyverno.io require-probes "*) echo validatingpolicy.policies.kyverno.io/require-probes ;;
  *" get validatingpolicies.policies.kyverno.io "*)
    echo "Error from server (NotFound): validatingpolicies.policies.kyverno.io \"$4\" not found" >&2
    exit 1 ;;
  *" get policyreports.wgpolicyk8s.io -A "*) cat "$d/polr.json" ;;
  *" get replicasets -A "*) cat "$d/rs.json" ;;
  *" get --raw "*) cat "$d/alerts.json" ;;
  *) echo "$*" >> "$d/refused.log"; echo "fake kubectl: refused: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$tmp/kubectl"
export KUBECTL="$tmp/kubectl"

# setup: a cluster READY for require-probes, results 10 minutes old.
#   - ReplicaSet home/ha-old at 0 replicas fails require-probes (ignored);
#   - Deployment kyverno/kyverno-admission-controller fails it, in an
#     excluded namespace (ignored);
#   - Deployment home/ha fails another policy (ignored);
#   - Service home/ha fails it, not a workload kind (ignored).
setup() {
  rm -rf "$tmp/d"; mkdir -p "$tmp/d"; export FAKE_DIR="$tmp/d"
  ts=$(($(date +%s) - 600))
  cat > "$FAKE_DIR/rs.json" <<'EOF'
{"items":[
{"metadata":{"namespace":"home","name":"ha-new"},"spec":{"replicas":1}},
{"metadata":{"namespace":"home","name":"ha-old"},"spec":{"replicas":0}}
]}
EOF
  cat > "$FAKE_DIR/polr.json" <<EOF
{"items":[
{"metadata":{"namespace":"home"},"scope":{"kind":"Deployment","name":"ha"},"results":[
  {"policy":"require-probes","result":"pass","message":"success","timestamp":{"seconds":$ts,"nanos":0}},
  {"policy":"require-requests-limits","result":"fail","message":"limits needed","timestamp":{"seconds":$ts,"nanos":0}}]},
{"metadata":{"namespace":"home"},"scope":{"kind":"ReplicaSet","name":"ha-old"},"results":[
  {"policy":"require-probes","result":"fail","message":"probes needed","timestamp":{"seconds":$((ts - 100)),"nanos":0}}]},
{"metadata":{"namespace":"home"},"scope":{"kind":"Service","name":"ha"},"results":[
  {"policy":"require-probes","result":"fail","message":"probes needed","timestamp":{"seconds":$ts,"nanos":0}}]},
{"metadata":{"namespace":"kyverno"},"scope":{"kind":"Deployment","name":"kyverno-admission-controller"},"results":[
  {"policy":"require-probes","result":"fail","message":"probes needed","timestamp":{"seconds":$ts,"nanos":0}}]},
{"metadata":{"namespace":"home"},"scope":{"kind":"Pod","name":"ha-new-x1"},"results":[]}
]}
EOF
  echo '[{"labels":{"alertname":"Watchdog"}}]' > "$FAKE_DIR/alerts.json"
}

# add_report <namespace> <kind> <name> <result> <message> [seconds]
add_report() {
  jq --arg ns "$1" --arg k "$2" --arg n "$3" --arg r "$4" --arg m "$5" --argjson s "${6:-$(date +%s)}" \
    '.items += [{metadata: {namespace: $ns}, scope: {kind: $k, name: $n},
                 results: [{policy: "require-probes", result: $r, message: $m, timestamp: {seconds: $s, nanos: 0}}]}]' \
    "$FAKE_DIR/polr.json" > "$FAKE_DIR/p" && mv "$FAKE_DIR/p" "$FAKE_DIR/polr.json"
}

run() { out=$(bash "$SCRIPT" "${1:-require-probes}" 2>&1); rc=$?; }

echo "ready"
setup
run
expect_eq "exit 0" 0 "$rc"
expect_eq "output" "$(printf 'K1 ok\nK2 ok\nREADY')" "$out"

echo "one failing Deployment"
setup
add_report home Deployment ha-probe fail "Every container needs a readinessProbe and a livenessProbe."
add_report home ReplicaSet ha-new fail "Every container needs a readinessProbe and a livenessProbe."
add_report home Pod ha-new-x2 skip "PolicyException"
run
expect_eq "exit 1" 1 "$rc"
expect_contains "names the Deployment and its message" \
  "K1 FAIL home/Deployment/ha-probe: Every container needs a readinessProbe and a livenessProbe." "$out"
expect_contains "names a ReplicaSet above 0" "K1 FAIL home/ReplicaSet/ha-new:" "$out"
expect_contains "K2 still passes" "K2 ok" "$out"
expect_eq "last line NOT READY" "NOT READY" "$(printf '%s\n' "$out" | tail -1)"
expect_eq "one line per failing object" 2 "$(printf '%s\n' "$out" | grep -c '^K1 FAIL')"

echo "ignored results"
case "$out" in
  *ha-old*) bad "a ReplicaSet at 0 replicas is ignored" ;;
  *) ok "a ReplicaSet at 0 replicas is ignored" ;;
esac
case "$out" in
  *kyverno/*) bad "an excluded namespace is ignored" ;;
  *) ok "an excluded namespace is ignored" ;;
esac
case "$out" in
  *Service/*|*ha-new-x2*) bad "a non-workload kind and a skip are ignored" ;;
  *) ok "a non-workload kind and a skip are ignored" ;;
esac

echo "excluded namespaces come from scripts/ci/kyverno.sh"
setup
add_report tailscale Deployment operator fail "probes needed"
add_report cilium DaemonSet cilium fail "probes needed"
run
expect_eq "exit 0" 0 "$rc"

echo "stale reports"
setup
jq --argjson s $(($(date +%s) - 3 * 3600)) '(.items[].results[].timestamp.seconds) = $s' \
  "$FAKE_DIR/polr.json" > "$FAKE_DIR/p" && mv "$FAKE_DIR/p" "$FAKE_DIR/polr.json"
run
expect_eq "exit 1" 1 "$rc"
expect_contains "K1 still passes" "K1 ok" "$out"
expect_contains "K2 names the age" "K2 FAIL newest PolicyReport result is 180 minutes old (limit 120)" "$out"
expect_eq "last line NOT READY" "NOT READY" "$(printf '%s\n' "$out" | tail -1)"

echo "no timestamp at all"
setup
echo '{"items":[]}' > "$FAKE_DIR/polr.json"
run
expect_eq "exit 1" 1 "$rc"
expect_contains "K2 fails without a timestamp" "K2 FAIL no PolicyReport result has a timestamp" "$out"

echo "KyvernoReportsStale firing"
setup
echo '[{"labels":{"alertname":"Watchdog"}},{"labels":{"alertname":"KyvernoReportsStale"}}]' > "$FAKE_DIR/alerts.json"
run
expect_eq "exit 1" 1 "$rc"
expect_contains "K2 names the alert" "K2 FAIL KyvernoReportsStale is firing" "$out"

echo "Alertmanager answer not JSON"
setup
echo '<html>503</html>' > "$FAKE_DIR/alerts.json"
run
expect_eq "exit 1" 1 "$rc"
expect_contains "K2 fails" "K2 FAIL Alertmanager answer not parseable" "$out"

echo "unknown policy"
setup
run require-nothing
expect_eq "exit 1" 1 "$rc"
expect_eq "output" "NOT READY: no ValidatingPolicy require-nothing" "$out"

echo "kubectl failure"
setup
touch "$FAKE_DIR/down"
run
expect_eq "exit 1" 1 "$rc"
expect_contains "NOT READY with the error" \
  "NOT READY: ValidatingPolicy require-probes not readable: Unable to connect to the server" "$out"
case "$out" in
  *READY*NOT*|*K1*) bad "nothing else printed" ;;
  *) ok "nothing else printed" ;;
esac

echo "unparseable report"
setup
echo '{"items":[' > "$FAKE_DIR/polr.json"
run
expect_eq "exit 1" 1 "$rc"
expect_contains "NOT READY with the error" "NOT READY: policyreports not parseable:" "$out"

echo "usage"
bash "$SCRIPT" 'Bad_Policy' > /dev/null 2>&1; expect_eq "rejects an invalid name" 64 "$?"
bash "$SCRIPT" > /dev/null 2>&1; expect_eq "rejects no argument" 64 "$?"

echo "read-only"
setup
"$KUBECTL" --request-timeout=10s -n home delete pod x > /dev/null 2>&1
expect_eq "the fake refuses a write verb" 99 "$?"
expect_eq "the refused write is logged" "--request-timeout=10s -n home delete pod x" "$(cat "$FAKE_DIR/refused.log")"
setup
run
add_report home Deployment ha-probe fail "probes needed"; run
run require-nothing
if [ -s "$FAKE_DIR/refused.log" ]; then bad "the script made a refused call: $(cat "$FAKE_DIR/refused.log")"; else ok "the script made no refused call"; fi
others=$(grep -v -E '^--request-timeout=10s get ' "$FAKE_DIR/calls.log" || true)
expect_eq "every call is a get with a 10s timeout" "" "$others"

finish
