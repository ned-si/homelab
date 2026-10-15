#!/bin/bash
# test_maintenance_silence.sh -- scripts/maintenance-silence.sh against a
# stubbed `kubectl`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/bash/lib.sh
. "$HERE/lib.sh"
SCRIPT="$REPO_ROOT/scripts/maintenance-silence.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/kubectl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
[ "${KUBECTL_FAIL:-}" = 1 ] && exit 1
echo 0b5b7c1e-6d3a-4f43-9d2c-1f0e2a3b4c5d
EOF
chmod +x "$tmp/bin/kubectl"
export KUBECTL_LOG="$tmp/kubectl.log"

# run <args...>: print "rc=<n>" and the output, stdout and stderr together.
run() {
  : > "$KUBECTL_LOG"
  local rc=0 out
  out=$(PATH="$tmp/bin:$PATH" SILENCE_AUTHOR=tester "$SCRIPT" "$@" 2>&1) || rc=$?
  printf 'rc=%s\n%s' "$rc" "$out"
}

echo "maintenance-silence"
out=$(run keycloak 30m "PR 123 keycloak-db image")
expect_contains "namespace: ok" "rc=0" "$out"
expect_contains "namespace: prints the id" "0b5b7c1e-6d3a-4f43-9d2c-1f0e2a3b4c5d" "$out"
log=$(cat "$KUBECTL_LOG")
expect_contains "namespace: exec amtool in the Alertmanager pod" \
  "-n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 silence add" "$log"
expect_contains "namespace: matcher" "--duration=30m namespace=keycloak" "$log"
expect_contains "namespace: comment and author" "--author=tester --comment=maintenance: PR 123 keycloak-db image" "$log"

out=$(run node/homelab-w-1 1h30m "Talos upgrade")
expect_contains "node: ok" "rc=0" "$out"
expect_contains "node: matcher" "--duration=1h30m node=homelab-w-1" "$(cat "$KUBECTL_LOG")"

out=$(run cluster 2h "power work")
expect_contains "cluster: never the Watchdog" "--duration=2h alertname!=Watchdog" "$(cat "$KUBECTL_LOG")"

out=$(run --expire 0b5b7c1e-6d3a-4f43-9d2c-1f0e2a3b4c5d)
expect_contains "expire: ok" "rc=0" "$out"
expect_contains "expire: amtool" "silence expire 0b5b7c1e-6d3a-4f43-9d2c-1f0e2a3b4c5d" "$(cat "$KUBECTL_LOG")"

for bad_args in "keycloak 13h x" "keycloak 0m x" "keycloak 30 x" "keycloak 30m" "Keycloak 30m x" \
  "node/ 30m x" "keycloak 30m  " "--expire nope"; do
  # shellcheck disable=SC2086 # split into arguments on purpose
  out=$(run $bad_args)
  expect_contains "usage: $bad_args" "rc=64" "$out"
  expect_eq "usage: $bad_args: no kubectl call" "" "$(cat "$KUBECTL_LOG")"
done
out=$(run keycloak 30m "  ")
expect_contains "blank reason: usage" "rc=64" "$out"

out=$(KUBECTL_FAIL=1 run keycloak 30m "x")
expect_contains "Alertmanager error: rc=1" "rc=1" "$out"
expect_contains "Alertmanager error: says so" "refused the silence" "$out"

finish
