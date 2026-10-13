#!/bin/bash
# talos-validate.sh -- the `talos` CI check. Offline: no cluster, no Image
# Factory request, no real secrets.
#
#   1. talhelper validate talconfig
#   2. throwaway secrets (talhelper gensecret), then scripts/talos-genconfig.sh
#   3. talosctl validate --mode metal on every generated machine config
#   4. invariants the configs must keep:
#        - one config per node: 3 control planes, 1 worker
#        - the installer image is the pinned RK1 schematic at talosVersion
#        - VIP 192.168.1.11 on the control planes only
#        - kube-proxy disabled, no Flannel, SecurityProfileConfig present
#        - WORKLOAD_ISOLATION=true switches workload isolation on
#        - talos/clusterconfig/ and plaintext talsecret files are git-ignored
#
# Needs talhelper and talosctl on PATH. Generated files stay in a temp dir that
# is deleted on exit; they are never printed (they hold the throwaway keys).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Image Factory schematic for the Turing RK1 (overlay sbc-rockchip/turingrk1 +
# siderolabs/iscsi-tools). The nodes are flashed with this ID's disk image, so a
# change to the schematic in talconfig.yaml must change this line too.
EXPECTED_SCHEMATIC=ca77d17f5b2c67e1fdb32a57cdbb166e20b8e19010ab6d35a888970958d76c02
VIP=192.168.1.11

fail=0
bad() { echo "::error::talos-validate: $*" >&2; fail=1; }
ok() { echo "ok  $*"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Print the YAML document of kind $1 in file $2.
doc_of() {
  awk -v kind="$1" '
    /^---[[:space:]]*$/ { if (hit) printf "%s", buf; buf = ""; hit = 0; next }
    { buf = buf $0 "\n" }
    $0 == "kind: " kind { hit = 1 }
    END { if (hit) printf "%s", buf }
  ' "$2"
}

talhelper validate talconfig talos/talconfig.yaml
ok "talhelper validate talconfig"

(cd talos && talhelper gensecret) > "$tmp/talsecret.yaml"

TALOS_SECRET_FILE="$tmp/talsecret.yaml" TALOS_OUT_DIR="$tmp/default" \
  scripts/talos-genconfig.sh
TALOS_SECRET_FILE="$tmp/talsecret.yaml" TALOS_OUT_DIR="$tmp/isolated" WORKLOAD_ISOLATION=true \
  scripts/talos-genconfig.sh >/dev/null
if WORKLOAD_ISOLATION=yes TALOS_SECRET_FILE="$tmp/talsecret.yaml" TALOS_OUT_DIR="$tmp/bad" \
  scripts/talos-genconfig.sh >/dev/null 2>&1; then
  bad "WORKLOAD_ISOLATION=yes was accepted"
else
  ok "WORKLOAD_ISOLATION rejects values other than true|false"
fi

talos_version=$(sed -n 's/^talosVersion:[[:space:]]*//p' talos/talconfig.yaml)
[ -n "$talos_version" ] || bad "no talosVersion in talos/talconfig.yaml"
installer="factory.talos.dev/metal-installer/$EXPECTED_SCHEMATIC:$talos_version"

cps=0
workers=0
for f in "$tmp"/default/*.yaml "$tmp"/isolated/*.yaml; do
  name=${f#"$tmp"/}
  if talosctl validate --mode metal --config "$f" > "$tmp/validate.log" 2>&1; then
    ok "talosctl validate --mode metal $name"
  else
    bad "talosctl validate --mode metal $name: $(tail -n 5 "$tmp/validate.log")"
  fi
  # Indentation differs between talhelper (2) and talosctl (4) output.
  grep -qE "^ +image: $installer\$" "$f" || bad "$name: install image is not $installer"
  # Talos 1.14 deploys Flannel only when a KubeFlannelCNIConfig document exists.
  if grep -q -e '^kind: KubeFlannelCNIConfig$' -e 'name: flannel$' "$f"; then
    bad "$name: Flannel is configured; Cilium is the CNI"
  fi
  doc_of SysctlConfig "$f" | grep -qE '^ +kernel\.panic_on_oops: "1"$' || bad "$name: kernel.panic_on_oops is not 1"
  case "$f" in
    "$tmp"/isolated/*) want=true ;;
    *) want=false ;;
  esac
  doc_of SecurityProfileConfig "$f" | grep -q "^workloadIsolation: $want\$" \
    || bad "$name: SecurityProfileConfig workloadIsolation is not $want"

  [ "${f#"$tmp"/default/}" != "$f" ] || continue
  if grep -qE '^ +type: controlplane$' "$f"; then
    cps=$((cps + 1))
    doc_of Layer2VIPConfig "$f" | grep -q "^name: $VIP\$" || bad "$name: no Layer2VIPConfig for $VIP"
    doc_of KubeProxyConfig "$f" | grep -q '^enabled: false$' || bad "$name: kube-proxy is not disabled"
    for k in KubeControllerManagerConfig KubeSchedulerConfig; do
      doc_of "$k" "$f" | grep -qE '^ +bind-address: 0\.0\.0\.0$' || bad "$name: $k does not bind metrics on 0.0.0.0"
    done
    grep -qE '^ +listen-metrics-urls: http://0\.0\.0\.0:2381$' "$f" || bad "$name: etcd metrics not on 0.0.0.0:2381"
  elif grep -qE '^ +type: worker$' "$f"; then
    workers=$((workers + 1))
    if grep -q '^kind: Layer2VIPConfig$' "$f"; then bad "$name: worker carries the API VIP"; fi
  else
    bad "$name: neither controlplane nor worker"
  fi
done
[ "$cps" -eq 3 ] && [ "$workers" -eq 1 ] || bad "expected 3 control planes and 1 worker, got $cps and $workers"
ok "invariants checked ($cps control planes, $workers worker)"

# Generated configs and plaintext secrets must never be committable.
for p in talos/clusterconfig/homelab-homelab-cp-1.yaml talos/clusterconfig/talosconfig \
  talos/talsecret.yaml talos/talosconfig; do
  git check-ignore -q "$p" || bad "$p is not git-ignored"
done
git check-ignore -q talos/talsecret.sops.yaml && bad "talos/talsecret.sops.yaml must stay committable"
ok "git-ignore rules"

exit "$fail"
