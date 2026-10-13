# shellcheck shell=bash
# cluster.sh -- helpers shared by the operator scripts that read the cluster
# (scripts/status.sh, scripts/smoke.sh, scripts/graceful-startup.sh).
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

# etcd_health_json: `etcdctl endpoint health --cluster -w json` from the first
# etcd pod that answers (read-only). Prints the JSON array, or nothing.
etcd_health_json() {
  local p out
  for p in $(k -n kube-system get pods -l component=etcd -o name 2>/dev/null); do
    out=$(k -n kube-system exec "${p#pod/}" -- etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
      --key=/etc/kubernetes/pki/etcd/healthcheck-client.key endpoint health --cluster -w json 2>/dev/null) \
      && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 && { printf '%s\n' "$out"; return 0; }
  done
  return 1
}

# wan_in_git <repo root>: the single --default-targets address in
# infrastructure/external-dns/values.yaml (CI rule wan-ip-single-source).
wan_in_git() {
  sed -n 's/^[[:space:]]*-[[:space:]]*--default-targets=\([0-9.]*\)[[:space:]]*$/\1/p' \
    "$1/infrastructure/external-dns/values.yaml" 2>/dev/null | head -n 1
}
