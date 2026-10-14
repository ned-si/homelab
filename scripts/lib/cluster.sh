# shellcheck shell=bash
# cluster.sh -- helpers shared by the operator scripts that read the cluster
# (scripts/status.sh, scripts/smoke.sh).
# Source it; it defines functions and sets nothing else. Bash 3.2 compatible.

# Colours only on a terminal, and never when NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_CYAN=$'\033[36m' C_OFF=$'\033[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_OFF=""
fi

step() { printf '\n%s=== %s ===%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()   { printf '%s  %s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '%s  %s%s\n' "$C_YELLOW" "$*" "$C_OFF"; }
bad()  { printf '%s  %s%s\n' "$C_RED" "$*" "$C_OFF"; }
die()  { bad "$*" >&2; exit 1; }

# k <args>: kubectl with a bounded request (macOS has no `timeout`).
k() { kubectl --request-timeout="${KUBECTL_TIMEOUT:-10s}" "$@"; }

is_ipv4() {
  printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
  local IFS=. o
  for o in $1; do [ "$o" -le 255 ] || return 1; done
}

# talos <args>: talosctl, bounded by an alarm (talosctl has no timeout flag).
# Uses $TALOSCONFIG, or talosctl's default config.
talos() { perl -e 'alarm shift @ARGV; exec { $ARGV[0] } @ARGV or exit 127' "${TALOS_TIMEOUT:-20}" talosctl "$@"; }

# talos_cp_ips: the InternalIP of every Talos control-plane node, one per line.
talos_cp_ips() {
  k get nodes -o json 2>/dev/null | jq -r '.items[]
    | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null)
    | select((.status.nodeInfo.osImage // "") | startswith("Talos"))
    | [.status.addresses[]? | select(.type == "InternalIP") | .address][0] // empty'
}

# etcd_health_json: the etcd service health of every control-plane node
# (`talosctl get services etcd`, read-only), as
# `[{endpoint: "https://<ip>:2379", health: true|false}, ...]`. Talos runs etcd
# as a system service, not a pod. Prints the JSON array, or nothing.
etcd_health_json() {
  local out ip h arr='[]'
  command -v talosctl >/dev/null 2>&1 || return 1
  out=$(talos_cp_ips)
  [ -n "$out" ] || return 1
  for ip in $out; do
    h=$(talos -n "$ip" get services etcd -o json </dev/null 2>/dev/null | jq -r '.spec.healthy == true' 2>/dev/null)
    [ "$h" = true ] || h=false
    arr=$(jq -c --arg e "https://$ip:2379" --argjson h "$h" '. + [{endpoint: $e, health: $h}]' <<<"$arr")
  done
  printf '%s\n' "$arr"
}

# wan_in_git <repo root>: the single --default-targets address in
# infrastructure/external-dns/values.yaml (CI rule wan-ip-single-source).
wan_in_git() {
  sed -n 's/^[[:space:]]*-[[:space:]]*--default-targets=\([0-9.]*\)[[:space:]]*$/\1/p' \
    "$1/infrastructure/external-dns/values.yaml" 2>/dev/null | head -n 1
}
