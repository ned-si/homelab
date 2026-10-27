#!/bin/bash
# Tests for scripts/alert-triage-job.sh with a fake triage.sh and curl.
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/alert-triage-job.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/triage" <<'FAKE'
#!/bin/bash
echo "$*" > "$FAKE_DIR/triage.args"
cat "$FAKE_DIR/triage.out"
exit "$(cat "$FAKE_DIR/triage.rc")"
FAKE
cat > "$tmp/curl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_DIR/curl.args"
[ ! -f "$FAKE_DIR/curl.fail" ]
FAKE
chmod +x "$tmp/triage" "$tmp/curl"
export FAKE_DIR="$tmp" TRIAGE="$tmp/triage" CURL="$tmp/curl" NTFY_URL="https://ntfy.test/topic"
export ALERTNAME=GatewayDown INCIDENT_ID=3f2a9c0d1e4b5a6f FIX=none
unset STORE_URL

cat > "$tmp/triage.out" <<'EOF'
== State (scripts/status.sh)
  gateway/shared  NOT PROGRAMMED  secret-host.internal.test
✗ 3 problem(s)
== Warning events, last 30 min (4)
gateway/Pod/envoy-1 BackOff x4: Back-off restarting failed container
== Firing alerts (unavailable: the Alertmanager API)
== Merged to main since 6 hours ago (1)
2026-10-27 abc1234 fix(gateway): something (#999)
EOF
echo 1 > "$tmp/triage.rc"

# 1. Findings: counts and the incident in the message, nothing from the body.
out=$(bash "$SCRIPT"); rc=$?
expect_eq "findings are not a failure" 0 "$rc"
expect_eq "triage.sh gets the alert name only" "GatewayDown" "$(cat "$tmp/triage.args")"
body=$(grep -A3 -- '--data-binary' "$tmp/curl.args" | sed -n 2,4p)
expect_eq "message counts" "Snapshot: 3 problems, 4 warning events, ? firing alerts, 1 merges (6 h)" "$(sed -n 1p <<<"$body")"
expect_eq "message fix line" "Fix: none for this alert" "$(sed -n 2p <<<"$body")"
expect_eq "message link (no STORE_URL)" "incident.id=3f2a9c0d1e4b5a6f" "$(sed -n 3p <<<"$body")"
case "$(cat "$tmp/curl.args")" in
  *secret-host*|*envoy-1*|*abc1234*) bad "nothing from the snapshot body in the message" ;;
  *) ok "nothing from the snapshot body in the message" ;;
esac
expect_contains "title" "Title: triage: GatewayDown" "$(cat "$tmp/curl.args")"
expect_contains "low priority" "Priority: low" "$(cat "$tmp/curl.args")"
first=$(head -n 1 <<<"$out")
expect_eq "log line shape" "snapshot 3f2a9c0d1e4b5a6f GatewayDown == State (scripts/status.sh)" \
  "$(jq -r '"\(.event) \(."incident.id") \(.alertname) \(.msg)"' <<<"$first")"
expect_eq "every output line logged" "$(($(wc -l < "$tmp/triage.out") + 1))" "$(grep -c . <<<"$out")"

# 2. STORE_URL: the link carries the incident id; a fix is mentioned.
out=$(STORE_URL='https://store.test/logs?q=incident.id%3D{id}' FIX=GatewayDown bash "$SCRIPT")
expect_contains "store link" "https://store.test/logs?q=incident.id%3D3f2a9c0d1e4b5a6f" "$(cat "$tmp/curl.args")"
expect_contains "fix line" "Fix: started, see the store" "$(cat "$tmp/curl.args")"

# 3. A healthy cluster.
printf '== State (scripts/status.sh)\n✓ no problems\n== Warning events, last 30 min (0)\n== Firing alerts (0)\n== Merged to main since 6 hours ago (0)\n' > "$tmp/triage.out"
echo 0 > "$tmp/triage.rc"
bash "$SCRIPT" >/dev/null
expect_contains "zero counts" "Snapshot: 0 problems, 0 warning events, 0 firing alerts, 0 merges (6 h)" "$(cat "$tmp/curl.args")"

# 4. triage.sh failed: the message says so and the Job fails.
echo 2 > "$tmp/triage.rc"
out=$(bash "$SCRIPT"); rc=$?
expect_eq "failed run exits 1" 1 "$rc"
expect_contains "message says it failed" "Snapshot: failed (triage.sh exit 2)" "$(cat "$tmp/curl.args")"
expect_contains "failed event logged" '"event":"failed"' "$out"

# 5. A rejected name runs nothing and sends nothing.
rm -f "$tmp/triage.args" "$tmp/curl.args"
out=$(ALERTNAME='x;id' bash "$SCRIPT"); rc=$?
expect_eq "rejected name exits 1" 1 "$rc"
expect_contains "rejected name logged" "alertname rejected" "$out"
if [ ! -f "$tmp/triage.args" ] && [ ! -f "$tmp/curl.args" ]; then ok "nothing run or sent"; else bad "nothing run or sent"; fi

# 6. A failed ntfy post fails the Job.
echo 0 > "$tmp/triage.rc"; touch "$tmp/curl.fail"
bash "$SCRIPT" >/dev/null; rc=$?
expect_eq "ntfy failure exits 1" 1 "$rc"

finish
