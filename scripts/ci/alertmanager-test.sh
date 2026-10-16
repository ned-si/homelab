#!/bin/bash
# alertmanager-test.sh -- test the Alertmanager routing, grouping and
# inhibition in platform/kube-prometheus-stack/values.yaml.
#
#   1. `amtool check-config` on `.alertmanager.config`; every alert of the
#      PrometheusRules under platform/ and apps/ has `action: human` or
#      `action: auto`, one per alert name. Steps 2 to 4 add that label to
#      their alerts (unless they set one), as the rules do.
#   2. tests/alertmanager/routes.txt: one label set per line and the receiver
#      it must reach (`amtool config routes test --verify.receivers`).
#   3. tests/alertmanager/*.json: a scenario of firing alerts, the
#      notifications it must produce (`<receiver> <alertname>`, as a local
#      webhook sink receives them) and the alerts left uninhibited. Each
#      scenario starts a fresh Alertmanager with the real config, quiet
#      hours off so the result does not depend on the clock.
#   4. Quiet hours: every route to ntfy (and no other) mutes `quiet-hours`,
#      which covers 02:00 and not 08:05 Europe/Zurich, every day; the
#      Watchdog is the first route, to the heartbeat, never muted. Then a
#      real Alertmanager with the interval moved to end within 2 minutes
#      (amtool has no --time): node-down is muted while the Watchdog still
#      reaches the heartbeat and the guard topic still gets it, and ntfy
#      gets it exactly once after the end.
#
# The webhook URLs (`url_file`, the SOPS Secret) point at the sink instead,
# and every group_wait is 2s so a scenario takes seconds; routes, grouping
# and inhibit rules are the real ones.
#
# Requires alertmanager, amtool, yq v4, jq, curl and python3. Exit 1 on any
# failure.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
for t in alertmanager amtool yq jq curl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "alertmanager-test: $t not found" >&2; exit 1; }
done

AM_PORT=${AM_PORT:-19093}
SINK_PORT=${SINK_PORT:-19094}
work=$(mktemp -d)
sink_pid="" am_pid=""
# shellcheck disable=SC2329 # invoked by the trap
cleanup() {
  local p
  for p in $am_pid $sink_pid; do
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  rm -rf "$work"
}
trap cleanup EXIT
rc=0

# shellcheck disable=SC2016 # $n is a yq variable
SINK="http://127.0.0.1:$SINK_PORT/" yq '.alertmanager.config
  | (.receivers[] | select(has("webhook_configs"))) |= (
      .name as $n
      | .webhook_configs[] |= (del(.url_file) | .url = strenv(SINK) + $n))
  | (.route | .. | select(tag == "!!map" and has("group_wait")) | .group_wait) = "2s"' \
  platform/kube-prometheus-stack/values.yaml > "$work/am.yaml"

if ! amtool check-config "$work/am.yaml" >/dev/null; then
  amtool check-config "$work/am.yaml"
  exit 1
fi
echo "ok    amtool check-config"

# 1b. The class of every homelab alert: `action: human` (pages) or `action:
# auto` (Grafana only), one per alert name, from the PrometheusRule sources.
# Routes and scenarios get the label from here, so they test what the rules
# really send.
grep -rl '^kind: PrometheusRule' platform apps | sort | while read -r f; do
  yq -o=json 'select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(has("alert")) | {"alert": .alert, "action": (.labels.action // "")}' "$f" |
    jq -c --arg f "$f" '. + {file: $f}'
done > "$work/classes.jsonl"
if ! jq -s -e 'length > 0' "$work/classes.jsonl" >/dev/null; then
  echo "FAIL  alert classes: no PrometheusRule found under platform/ or apps/"; exit 1
fi
bad=$(jq -s -r '
  (.[] | select(.action != "human" and .action != "auto") | "\(.file): \(.alert) has action \"\(.action)\", want human or auto"),
  (group_by(.alert)[] | select((map(.action) | unique | length) > 1) | "\(.[0].alert): more than one action")' "$work/classes.jsonl")
if [ -n "$bad" ]; then
  printf 'FAIL  alert classes: %s\n' "$bad"; rc=1
else
  echo "ok    alert classes: $(jq -s 'map(.alert) | unique | length' "$work/classes.jsonl") alerts, each action human or auto"
fi
jq -s 'map({(.alert): .action}) | add' "$work/classes.jsonl" > "$work/actions.json"

# The label sets of a scenario or a route line, with the alert's action added
# unless it sets one.
with_action() { # JSON array of label sets on stdin
  jq -c --slurpfile a "$work/actions.json" \
    'map(if has("action") or ($a[0][.alertname] // "") == "" then . else . + {action: $a[0][.alertname]} end)'
}

# The scenarios run with quiet hours never active (year 2000).
yq '(.time_intervals[] | select(.name == "quiet-hours") | .time_intervals) = [{"years": ["2000"]}]' \
  "$work/am.yaml" > "$work/am-scenarios.yaml"

# 2. Routes.
while read -r want labels; do
  case "$want" in '' | '#'*) continue ;; esac
  # shellcheck disable=SC2086 # one argument per label
  labels=$(printf '%s\n' $labels | jq -R 'capture("(?<k>[^=]+)=(?<v>.*)") | {(.k): .v}' | jq -s 'add' |
    jq -s '.' | with_action | jq -r '.[0] | to_entries | map("\(.key)=\(.value)") | join(" ")')
  # shellcheck disable=SC2086 # one argument per label
  if got=$(amtool config routes test --config.file="$work/am.yaml" --verify.receivers="$want" $labels 2>&1); then
    echo "ok    $want <- $labels"
  else
    echo "FAIL  $labels: want $want, got $got"; rc=1
  fi
done < tests/alertmanager/routes.txt

# 3. Scenarios. The sink appends one line per notification to $work/sink.
python3 - "$SINK_PORT" "$work/sink" <<'EOF' &
import http.server, json, sys

port, out = int(sys.argv[1]), sys.argv[2]

class Sink(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        with open(out, "a") as f:
            f.write("%s %s\n" % (self.path.strip("/"), body["commonLabels"].get("alertname", "-")))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass

http.server.HTTPServer(("127.0.0.1", port), Sink).serve_forever()
EOF
sink_pid=$!

wait_ready() { # url
  local _
  for _ in $(seq 1 50); do
    curl -fsS -m 1 "$1" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}

start_am() { # config file; empties the sink
  : > "$work/sink"
  rm -rf "$work/data"
  alertmanager --config.file="$1" --storage.path="$work/data" \
    --web.listen-address="127.0.0.1:$AM_PORT" --cluster.listen-address= \
    --log.level=error > "$work/am.log" 2>&1 &
  am_pid=$!
  wait_ready "http://127.0.0.1:$AM_PORT/-/ready" && return 0
  cat "$work/am.log"
  stop_am
  return 1
}

stop_am() {
  kill "$am_pid" 2>/dev/null; wait "$am_pid" 2>/dev/null; am_pid=""
}

post_alerts() { # JSON array of label sets on stdin
  with_action | jq -c '[.[] | {labels: .}]' |
    curl -fsS -m 5 -H 'Content-Type: application/json' --data-binary @- \
      "http://127.0.0.1:$AM_PORT/api/v2/alerts" >/dev/null
}

for s in tests/alertmanager/*.json; do
  [ -f "$s" ] || continue
  if ! start_am "$work/am-scenarios.yaml"; then
    echo "FAIL  $s: Alertmanager did not start"; rc=1; continue
  fi
  jq '.alerts' "$s" | post_alerts || { echo "FAIL  $s: post"; rc=1; }
  sleep 6
  open=$(curl -fsS -m 5 "http://127.0.0.1:$AM_PORT/api/v2/alerts" |
    jq -r '.[] | select((.status.inhibitedBy // []) | length == 0) | .labels.alertname' | sort)
  stop_am
  for check in notifications uninhibited; do
    want=$(jq -r ".${check}[]" "$s" | sort)
    if [ "$check" = notifications ]; then got=$(sort "$work/sink"); else got=$open; fi
    if [ "$want" = "$got" ]; then
      echo "ok    $s: $(grep -c . <<<"$got") $check"
    else
      echo "FAIL  $s: $check"
      echo "      want: $(tr '\n' ';' <<<"$want")"
      echo "      got:  $(tr '\n' ';' <<<"$got")"
      rc=1
    fi
  done
done

# 4. Quiet hours. a) The routes and the interval, at Zurich wall-clock times.
yq -o=json '.' "$work/am.yaml" | python3 -c '
import json, sys

cfg, rc = json.load(sys.stdin), 0

def walk(route, receiver, path):
    global rc
    receiver = route.get("receiver", receiver)
    muted = "quiet-hours" in route.get("mute_time_intervals", [])
    if path != "route" and muted != (receiver == "ntfy"):
        print("FAIL  quiet hours: %s (%s) %s" % (path, receiver, "mutes it" if muted else "does not mute it"))
        rc = 1
    for i, child in enumerate(route.get("routes", [])):
        walk(child, receiver, "%s.routes[%d]" % (path, i))

walk(cfg["route"], None, "route")
if rc == 0:
    print("ok    quiet hours: every ntfy route mutes quiet-hours, no other route does")

# The dead-man path: the Watchdog reaches healthchecks.io first, unmuted,
# at least every 5 minutes, through the heartbeat URL.
first = cfg["route"]["routes"][0]
hb = [r for r in cfg["receivers"] if r["name"] == "heartbeat"]
if (first.get("receiver") == "heartbeat" and len(first.get("matchers", [])) == 1 and "Watchdog" in first["matchers"][0]
        and not first.get("mute_time_intervals") and not first.get("continue")
        and first.get("repeat_interval") in ("1m", "5m") and hb
        and hb[0]["webhook_configs"][0]["url"].endswith("/heartbeat")):
    print("ok    heartbeat: Watchdog is the first route, unmuted, every %s" % first["repeat_interval"])
else:
    print("FAIL  heartbeat: want Watchdog as the first route to heartbeat, unmuted, repeat 5m; got %s" % first)
    rc = 1

ivs = [t for n in cfg.get("time_intervals", []) if n["name"] == "quiet-hours" for t in n["time_intervals"]]
if not ivs or any(set(t) != {"times", "location"} or t["location"] != "Europe/Zurich" for t in ivs):
    print("FAIL  quiet hours: want times only (every day), location Europe/Zurich; got %s" % ivs)
    sys.exit(1)

def minutes(hhmm):
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)

def muted(hhmm):
    return any(minutes(r["start_time"]) <= minutes(hhmm) < minutes(r["end_time"]) for t in ivs for r in t["times"])

for hhmm, want in [("22:59", False), ("23:00", True), ("02:00", True), ("07:59", True), ("08:00", False), ("08:05", False)]:
    if muted(hhmm) == want:
        print("ok    quiet hours: %s Europe/Zurich %s" % (hhmm, "muted" if want else "delivered"))
    else:
        print("FAIL  quiet hours: %s Europe/Zurich, want %s" % (hhmm, "muted" if want else "delivered"))
        rc = 1
sys.exit(rc)
' || rc=1

# b) A real Alertmanager with the interval at 00:00 UTC until the next minute
# boundary at least 20 s away, and every group_interval 5s so the first flush
# after the end comes at once.
while :; do
  read -r h m sec <<<"$(date -u '+%H %M %S')"
  now=$((10#$h * 3600 + 10#$m * 60 + 10#$sec))
  end_min=$((now / 60 + 1))
  [ $((now % 60)) -gt 40 ] && end_min=$((end_min + 1))
  [ "$end_min" -le 1440 ] && break
  sleep 30 # a range cannot cross midnight UTC
done
end=$(printf '%02d:%02d' $((end_min / 60)) $((end_min % 60)))
deadline=$(($(date +%s) + end_min * 60 - now))
# shellcheck disable=SC2016 # strenv, not a shell variable
END=$end yq '(.time_intervals[] | select(.name == "quiet-hours") | .time_intervals) =
    [{"times": [{"start_time": "00:00", "end_time": strenv(END)}], "location": "UTC"}]
  | (.route | .. | select(tag == "!!map" and has("group_interval")) | .group_interval) = "5s"' \
  "$work/am.yaml" > "$work/am-quiet.yaml"
if start_am "$work/am-quiet.yaml"; then
  jq '.alerts + [{"alertname": "Watchdog", "severity": "none"}]' tests/alertmanager/node-down.json |
    post_alerts || { echo "FAIL  quiet hours: post"; rc=1; }
  sleep 5
  got=$(LC_ALL=C sort "$work/sink" | tr '\n' ';')
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FAIL  quiet hours: the interval ended before the check"; rc=1
  elif [ "$got" = "heartbeat Watchdog;ntfy-guard HomelabNodeNotReady;" ]; then
    echo "ok    quiet hours: node-down muted until $end UTC, Watchdog and the guard topic delivered"
  else
    echo "FAIL  quiet hours: while muted, want heartbeat Watchdog and ntfy-guard; got $got"; rc=1
  fi
  sleep $((deadline - $(date +%s) + 12))
  got=$(LC_ALL=C sort "$work/sink" | tr '\n' ';')
  if [ "$got" = "heartbeat Watchdog;ntfy HomelabNodeDown;ntfy-guard HomelabNodeNotReady;" ]; then
    echo "ok    quiet hours: node-down notified once after $end UTC"
  else
    echo "FAIL  quiet hours: after the end, want one HomelabNodeDown; got $got"; rc=1
  fi
  stop_am
else
  echo "FAIL  quiet hours: Alertmanager did not start"; rc=1
fi
exit "$rc"
