#!/bin/bash
# Tests for scripts/alert-triage.sh with a fake kubectl, curl and triage.sh.
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/scripts/alert-triage.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Fake kubectl: ConfigMaps as files in $FAKE_DIR/cm/<name>, created at
# $FAKE_DIR/cm/<name>.ts (ISO time). Logs every call.
cat > "$tmp/kubectl" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/kubectl.log"
args=$(echo "$*" | sed 's/-n monitoring //; s/--request-timeout=20s //')
set -- $args
cm="$FAKE_DIR/cm"
case "$1 $2" in
  "get configmap")
    if [ "$3" = -l ]; then
      printf '{"items":['; sep=""
      for f in "$cm"/*.ts; do [ -f "$f" ] || continue; n=$(basename "$f" .ts)
        printf '%s{"metadata":{"name":"%s","creationTimestamp":"%s"}}' "$sep" "$n" "$(cat "$f")"; sep=,; done
      echo ']}'
    else
      [ -f "$cm/$3" ] || exit 1
      jq -n --rawfile s "$cm/$3" '{data: {state: $s}}'
    fi ;;
  "create configmap")
    case "$*" in
      *--dry-run=client*) echo "state=${4#--from-literal=state=}" ;;
      *) [ -f "$cm/$3" ] && exit 1; cp "${4#--from-file=snapshot=}" "$cm/$3"; echo "2026-10-27T09:00:00Z" > "$cm/$3.ts" ;;
    esac ;;
  "label --local") cat ;;
  "label configmap") ;;
  "apply -f") v=$(sed -n 's/^state=//p'); printf '%s' "$v" > "$cm/alert-triage-state" ;;
  "delete configmap") rm -f "$cm/$3" "$cm/$3.ts" ;;
  *) exit 2 ;;
esac
FAKE
# Fake curl: the groups fixture for Alertmanager, the body to ntfy.log.
cat > "$tmp/curl" <<'FAKE'
#!/bin/bash
url=${!#}
case "$url" in
  *api/v2/alerts/groups*) [ -f "$FAKE_DIR/groups.json" ] || exit 22; cat "$FAKE_DIR/groups.json" ;;
  *ntfy*) while [ $# -gt 1 ]; do case "$1" in --data-binary) printf '%s\n--\n' "$2" >> "$FAKE_DIR/ntfy.log"; shift ;; -H) echo "$2" >> "$FAKE_DIR/ntfy.log"; shift ;; esac; shift; done ;;
esac
FAKE
cat > "$tmp/triage" <<'FAKE'
#!/bin/bash
echo "$1" >> "$FAKE_DIR/triage.log"
printf '== State (scripts/status.sh)\nsecret-ish detail 10.244.0.29\n== Warning events, last 30 min (4)\n== Firing alerts (2)\n'
exit "${TRIAGE_RC:-1}"
FAKE
chmod +x "$tmp/kubectl" "$tmp/curl" "$tmp/triage"
mkdir "$tmp/cm"
export FAKE_DIR="$tmp" KUBECTL="$tmp/kubectl" CURL="$tmp/curl" TRIAGE="$tmp/triage" \
  NTFY_URL="https://ntfy.example/topic" NOW=1793091600   # 2026-10-27T09:00:00Z

group() { # <alertname> <action> [receiver]
  printf '{"receiver":{"name":"%s"},"labels":{"alertname":"%s"},"alerts":[{"labels":{"alertname":"%s","action":"%s"}}]}' "${3:-ntfy}" "$1" "$1" "$2"
}
count() { local n=0 f; for f in "$tmp"/cm/alert-triage-*"$1"; do [ -f "$f" ] && n=$((n + 1)); done; echo "$n"; }

# 1. A new page: one run, one snapshot, one counts-only message.
echo "[$(group GatewayDown human),$(group PodNotReady ticket)]" > "$tmp/groups.json"
out=$(bash "$SCRIPT"); rc=$?
expect_eq "new page exits 0" 0 "$rc"
expect_eq "triage ran once, for the page only" "GatewayDown" "$(cat "$tmp/triage.log")"
expect_eq "one snapshot" 1 "$(count gatewaydown)"
expect_contains "snapshot name" "configmap/alert-triage-20261027t0900-gatewaydown" "$out"
msg=$(cat "$tmp/ntfy.log")
expect_contains "message title" "Title: triage: GatewayDown" "$msg"
expect_contains "message counts" "Warning events, last 30 min: 4; Firing alerts: 2" "$msg"
expect_contains "message read command" "get cm alert-triage-20261027t0900-gatewaydown" "$msg"
case "$msg" in *10.244.0.29*|*secret-ish*) bad "no snapshot body in the message" ;; *) ok "no snapshot body in the message" ;; esac

# 2. The same group on the next pass: no second run.
: > "$tmp/triage.log"; : > "$tmp/ntfy.log"
NOW=$((NOW + 120)) bash "$SCRIPT" >/dev/null
expect_eq "known group not run again" "" "$(cat "$tmp/triage.log")"
expect_eq "no second message" "" "$(cat "$tmp/ntfy.log")"

# 3. After STATE_TTL the group counts as new again.
NOW=$((NOW + 21700)) bash "$SCRIPT" >/dev/null
expect_eq "expired state, run again" "GatewayDown" "$(cat "$tmp/triage.log")"

# 4. Untrusted alert name: not run, recorded, not retried.
: > "$tmp/triage.log"
echo "[$(group 'x;rm -rf /' human)]" > "$tmp/groups.json"
out=$(bash "$SCRIPT"); rc=$?
expect_contains "rejected" "alertname rejected" "$out"
expect_eq "rejected name not run" "" "$(cat "$tmp/triage.log")"
out=$(bash "$SCRIPT")
case "$out" in *rejected*) bad "rejected group recorded, not retried" ;; *) ok "rejected group recorded, not retried" ;; esac

# 5. A failed triage run: exit 1, the message says so.
: > "$tmp/ntfy.log"
echo "[$(group EtcdNoLeader human)]" > "$tmp/groups.json"
TRIAGE_RC=2 bash "$SCRIPT" >/dev/null; rc=$?
expect_eq "failed run exits 1" 1 "$rc"
expect_contains "failure in the message" "triage.sh failed (exit 2)" "$(cat "$tmp/ntfy.log")"

# 6. Snapshots past SNAP_TTL are deleted, newer ones kept.
echo "2026-10-01T00:00:00Z" > "$tmp/cm/alert-triage-20261001t0000-old.ts"; : > "$tmp/cm/alert-triage-20261001t0000-old"
bash "$SCRIPT" >/dev/null
if [ -f "$tmp/cm/alert-triage-20261001t0000-old" ]; then bad "old snapshot deleted"; else ok "old snapshot deleted"; fi
expect_eq "recent snapshots kept (two runs of 1 and 3)" 2 "$(count gatewaydown)"
if [ -f "$tmp/cm/alert-triage-state" ]; then ok "state kept"; else bad "state kept"; fi

# 7. Alertmanager unreachable: exit 1, nothing run.
rm "$tmp/groups.json"; : > "$tmp/triage.log"
out=$(bash "$SCRIPT"); rc=$?
expect_eq "unreachable Alertmanager exits 1" 1 "$rc"
expect_contains "says so" "cannot read the alert groups" "$out"
case "$(cat "$tmp/kubectl.log")" in
  *" patch "*|*" edit "*|*"secret"*) bad "only ConfigMap calls" ;;
  *) ok "only ConfigMap calls" ;;
esac

finish
