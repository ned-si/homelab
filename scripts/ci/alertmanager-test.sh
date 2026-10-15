#!/bin/bash
# alertmanager-test.sh -- test the Alertmanager routing, grouping and
# inhibition in platform/kube-prometheus-stack/values.yaml.
#
#   1. `amtool check-config` on `.alertmanager.config`.
#   2. tests/alertmanager/routes.txt: one label set per line and the receiver
#      it must reach (`amtool config routes test --verify.receivers`).
#   3. tests/alertmanager/*.json: a scenario of firing alerts, the
#      notifications it must produce (`<receiver> <alertname>`, as a local
#      webhook sink receives them) and the alerts left uninhibited. Each
#      scenario starts a fresh Alertmanager with the real config.
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

# 2. Routes.
while read -r want labels; do
  case "$want" in '' | '#'*) continue ;; esac
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

for s in tests/alertmanager/*.json; do
  [ -f "$s" ] || continue
  : > "$work/sink"
  rm -rf "$work/data"
  alertmanager --config.file="$work/am.yaml" --storage.path="$work/data" \
    --web.listen-address="127.0.0.1:$AM_PORT" --cluster.listen-address= \
    --log.level=error > "$work/am.log" 2>&1 &
  am_pid=$!
  if ! wait_ready "http://127.0.0.1:$AM_PORT/-/ready"; then
    echo "FAIL  $s: Alertmanager did not start"; cat "$work/am.log"; rc=1
    kill "$am_pid" 2>/dev/null; am_pid=""; continue
  fi
  jq -c '[.alerts[] | {labels: .}]' "$s" |
    curl -fsS -m 5 -H 'Content-Type: application/json' --data-binary @- \
      "http://127.0.0.1:$AM_PORT/api/v2/alerts" >/dev/null || { echo "FAIL  $s: post"; rc=1; }
  sleep 6
  open=$(curl -fsS -m 5 "http://127.0.0.1:$AM_PORT/api/v2/alerts" |
    jq -r '.[] | select((.status.inhibitedBy // []) | length == 0) | .labels.alertname' | sort)
  kill "$am_pid" 2>/dev/null; wait "$am_pid" 2>/dev/null; am_pid=""
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
exit "$rc"
