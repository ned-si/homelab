#!/bin/bash
# Tests for scripts/triage.sh with a fake `kubectl`, `git` and status.sh.
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/triage.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Fake kubectl: the fixture named after the resource asked for; logs the calls.
cat > "$tmp/kubectl" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/kubectl.log"
case "$*" in
  *"get application "*) f=app ;;
  *"get events"*) f=events ;;
  *"--raw /api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts?"*) f=alerts ;;
  *) exit 2 ;;
esac
[ -f "$FAKE_DIR/$f.json" ] || exit 1
cat "$FAKE_DIR/$f.json"
FAKE
# Fake curl: the Alertmanager API at $AM_URL; logs the calls.
cat > "$tmp/curl" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/curl.log"
case "$*" in
  *"http://am.test:9093/api/v2/alerts?active=true&silenced=false&inhibited=false") cat "$FAKE_DIR/alerts.json" ;;
  *) exit 22 ;;
esac
FAKE
cat > "$tmp/git" <<'FAKE'
#!/bin/bash
case "$*" in
  *" log "*) cat "$FAKE_DIR/merges.txt" ;;
esac
FAKE
cat > "$tmp/status" <<'FAKE'
#!/bin/bash
cat "$FAKE_DIR/status.txt"
exit "$(cat "$FAKE_DIR/status.rc")"
FAKE
chmod +x "$tmp/kubectl" "$tmp/curl" "$tmp/git" "$tmp/status"
export FAKE_DIR="$tmp" KUBECTL="$tmp/kubectl" CURL="$tmp/curl" GIT="$tmp/git" STATUS="$tmp/status"

recent=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
old="2026-01-01T00:00:00Z"

healthy() {
  printf '=== Argo CD ===\n  52 Applications Synced/Healthy\n' > "$tmp/status.txt"; echo 0 > "$tmp/status.rc"
  # An old warning, and a recent Kyverno Audit result: neither is a finding.
  printf '{"items":[{"involvedObject":{"namespace":"mealie","kind":"Pod","name":"mealie-0"},"reason":"BackOff","message":"old","lastTimestamp":"%s","count":3},
    {"involvedObject":{"kind":"ValidatingPolicy","name":"require-ro-rootfs"},"reason":"PolicyViolation","message":"ReplicaSet theater/bazarr: fail; Root filesystem must be read-only.","lastTimestamp":"%s","count":9}]}' "$old" "$recent" > "$tmp/events.json"
  echo '[{"labels":{"alertname":"Watchdog"},"startsAt":"2026-10-26T00:00:00Z","status":{"silencedBy":[],"inhibitedBy":[]}}]' > "$tmp/alerts.json"
  : > "$tmp/merges.txt"
}

# 1. A healthy cluster: no finding, exit 0.
healthy
out=$(bash "$SCRIPT"); rc=$?
expect_eq "healthy cluster exits 0" 0 "$rc"
expect_contains "status.sh output included" "52 Applications Synced/Healthy" "$out"
expect_contains "old and Kyverno Audit events are not findings" "== Warning events, last 30 min (0)" "$out"
expect_contains "Watchdog is not a finding" "== Firing alerts (0)" "$out"

# 2. Something broken in every section.
printf '=== Argo CD ===\n  mealie OutOfSync Degraded\n' > "$tmp/status.txt"; echo 1 > "$tmp/status.rc"
echo '{"metadata":{"name":"mealie"},"status":{"sync":{"status":"OutOfSync","revision":"abc1234"},"health":{"status":"Degraded"},
  "conditions":[{"type":"SyncError","message":"one or more objects failed to apply"}],
  "resources":[{"kind":"Deployment","namespace":"mealie","name":"mealie","status":"Synced","health":{"status":"Degraded","message":"Deployment exceeded its progress deadline"}},
               {"kind":"Service","namespace":"mealie","name":"mealie","status":"Synced","health":{"status":"Healthy"}}]}}' > "$tmp/app.json"
printf '{"items":[{"involvedObject":{"namespace":"mealie","kind":"Pod","name":"mealie-0"},"reason":"BackOff","message":"Back-off restarting failed container","lastTimestamp":"%s","count":4},
  {"involvedObject":{"namespace":"theater","kind":"ReplicaSet","name":"x"},"reason":"PolicyViolation","message":"admission webhook denied the request: blocked by disallow-host-path","lastTimestamp":"%s"}]}' "$recent" "$recent" > "$tmp/events.json"
echo '[{"labels":{"alertname":"GatewayDown","severity":"critical","action":"human"},"startsAt":"2026-10-26T20:00:00Z","status":{"silencedBy":[],"inhibitedBy":[]}},
       {"labels":{"alertname":"PodNotReady","severity":"warning"},"startsAt":"2026-10-26T20:00:00Z","status":{"silencedBy":["s1"],"inhibitedBy":[]}}]' > "$tmp/alerts.json"
echo "2026-10-26 abc1234 fix(mealie): bump the image (#999)" > "$tmp/merges.txt"
out=$(bash "$SCRIPT" mealie); rc=$?
expect_eq "findings exit 1" 1 "$rc"
expect_contains "status.sh red output included" "mealie OutOfSync Degraded" "$out"
expect_contains "recent warning, counted" "mealie/Pod/mealie-0 BackOff x4" "$out"
expect_contains "a Kyverno admission denial is a finding" "blocked by disallow-host-path" "$out"
expect_contains "firing alert" "GatewayDown severity=critical action=human" "$out"
case "$out" in
  *PodNotReady*) bad "a silenced alert is not listed" ;;
  *) ok "a silenced alert is not listed" ;;
esac
expect_contains "recent merges" "abc1234 fix(mealie): bump the image (#999)" "$out"
expect_contains "application detail for an app target" "== Application mealie" "$out"
expect_contains "the app's failing condition" "condition SyncError: one or more objects failed to apply" "$out"
expect_contains "only the unhealthy resources" "resource Deployment mealie/mealie sync=Synced health=Degraded" "$out"
case "$out" in
  *"resource Service"*) bad "healthy resources are not listed" ;;
  *) ok "healthy resources are not listed" ;;
esac

# 3. An alert target prints its runbook's Confirm section.
healthy
out=$(bash "$SCRIPT" GatewayDown)
expect_contains "runbook Confirm section" "== Runbook: docs/runbooks/alerts/GatewayDown.md, Confirm" "$out"

# 4. A source that fails is reported, and the rest still runs.
rm "$tmp/events.json"
out=$(bash "$SCRIPT"); rc=$?
expect_contains "failed source is reported" "Warning events (unavailable" "$out"
expect_contains "the other sections still run" "== Firing alerts (0)" "$out"
expect_eq "an unavailable source counts as a finding" 1 "$rc"
case "$(cat "$tmp/kubectl.log")" in
  *" delete "*|*" apply "*|*" patch "*|*" edit "*) bad "only read-only kubectl calls" ;;
  *) ok "only read-only kubectl calls" ;;
esac
case "$(cat "$tmp/kubectl.log")" in
  *" exec "*) bad "no kubectl exec" ;;
  *) ok "no kubectl exec" ;;
esac

# 5. In the cluster: AM_URL is read directly, not through the apiserver.
healthy
: > "$tmp/kubectl.log"
echo '[{"labels":{"alertname":"GatewayDown","severity":"critical","action":"human"},"startsAt":"2026-10-26T20:00:00Z","status":{"silencedBy":[],"inhibitedBy":[]}}]' > "$tmp/alerts.json"
out=$(AM_URL=http://am.test:9093/ bash "$SCRIPT")
expect_contains "alerts read from AM_URL" "GatewayDown severity=critical action=human" "$out"
case "$(cat "$tmp/kubectl.log")" in
  *"--raw"*) bad "AM_URL set: no apiserver proxy call" ;;
  *) ok "AM_URL set: no apiserver proxy call" ;;
esac

# 6. An unreachable Alertmanager is reported, not an empty list.
out=$(AM_URL=http://down.test:9093 bash "$SCRIPT"); rc=$?
expect_contains "unreachable Alertmanager" "== Firing alerts (unavailable: the Alertmanager API)" "$out"
expect_eq "an unreachable Alertmanager is a finding" 1 "$rc"

finish
