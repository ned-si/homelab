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
#        - Talos API access from system-upgrade (tuppr) on the control planes
#        - the tailscale extension service as talos-<node> with tag:talos,
#          that name in certSANs, the tailnet hosts, kubelet and etcd on the LAN
#        - tuppr's target versions equal talosVersion and kubernetesVersion
#        - WORKLOAD_ISOLATION=true switches workload isolation on
#        - talos/clusterconfig/ and plaintext talsecret files are git-ignored
#
# Needs talhelper and talosctl on PATH. Generated files stay in a temp dir that
# is deleted on exit; they are never printed (they hold the throwaway keys).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Image Factory schematic for the Turing RK1 (overlay sbc-rockchip/turingrk1 +
# siderolabs/iscsi-tools + siderolabs/tailscale). The nodes run this ID's
# image, so a change to the schematic in talconfig.yaml must change this line
# too.
EXPECTED_SCHEMATIC=21cb209fd2bf7aa421d4f2ae391ca60c97b25694cda234c067f992a2709f0646
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

# The placeholder scripts/talos-genconfig.sh uses without the sealed env.
printf 'TS_OAUTH_SECRET: placeholder\n' > "$tmp/talenv.yaml"
talhelper validate talconfig talos/talconfig.yaml -e "$tmp/talenv.yaml"
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
  # Tailnet: talos-<node> with tag:talos, that name in apid's certificate,
  # every tailnet name in /etc/hosts, the kubelet on the LAN.
  short=${name#default/homelab-homelab-}
  short=${short%.yaml}
  ts_name="talos-$short.tail32a1fc.ts.net"
  ts=$(doc_of ExtensionServiceConfig "$f")
  printf '%s\n' "$ts" | grep -q '^name: tailscale$' || bad "$name: no ExtensionServiceConfig tailscale"
  printf '%s\n' "$ts" | grep -qE "^ +- TS_HOSTNAME=talos-$short\$" || bad "$name: TS_HOSTNAME is not talos-$short"
  printf '%s\n' "$ts" | grep -qE '^ +- TS_EXTRA_ARGS=--advertise-tags=tag:talos$' || bad "$name: not advertised as tag:talos"
  printf '%s\n' "$ts" | grep -qE '^ +- TS_AUTHKEY=placeholder\?ephemeral=false&preauthorized=true$' \
    || bad "$name: TS_AUTHKEY is not the substituted, non-ephemeral, pre-authorized key"
  grep -qE "^ +- $ts_name\$" "$f" || bad "$name: $ts_name not in certSANs"
  [ "$(grep -c '^kind: StaticHostConfig$' "$f")" -eq 4 ] || bad "$name: expected 4 StaticHostConfig documents"
  grep -qE '^ +- 192\.168\.1\.0/24$' "$f" || bad "$name: kubelet nodeIP.validSubnets is not the LAN"
  if grep -qE '^ +type: controlplane$' "$f"; then
    cps=$((cps + 1))
    doc_of Layer2VIPConfig "$f" | grep -q "^name: $VIP\$" || bad "$name: no Layer2VIPConfig for $VIP"
    doc_of KubeProxyConfig "$f" | grep -q '^enabled: false$' || bad "$name: kube-proxy is not disabled"
    for k in KubeControllerManagerConfig KubeSchedulerConfig; do
      doc_of "$k" "$f" | grep -qE '^ +bind-address: 0\.0\.0\.0$' || bad "$name: $k does not bind metrics on 0.0.0.0"
    done
    grep -qE '^ +listen-metrics-urls: http://0\.0\.0\.0:2381$' "$f" || bad "$name: etcd metrics not on 0.0.0.0:2381"
    grep -qE '^ +advertisedSubnets:$' "$f" || bad "$name: etcd advertisedSubnets not set"
    # tuppr (platform/tuppr) upgrades the nodes from this namespace.
    doc_of KubeTalosAPIAccessConfig "$f" | grep -qE '^ +- system-upgrade$' \
      || bad "$name: KubeTalosAPIAccessConfig does not allow system-upgrade"
  elif grep -qE '^ +type: worker$' "$f"; then
    workers=$((workers + 1))
    if grep -q '^kind: Layer2VIPConfig$' "$f"; then bad "$name: worker carries the API VIP"; fi
  else
    bad "$name: neither controlplane nor worker"
  fi
done
[ "$cps" -eq 3 ] && [ "$workers" -eq 1 ] || bad "expected 3 control planes and 1 worker, got $cps and $workers"
ok "invariants checked ($cps control planes, $workers worker)"

# tuppr rolls out the versions in its upgrade resources: they must be the ones
# in talconfig.yaml, which the machine configs are generated with.
k8s_version=$(sed -n 's/^kubernetesVersion:[[:space:]]*//p' talos/talconfig.yaml)
tuppr_talos=$(sed -n 's/^    version:[[:space:]]*//p' platform/tuppr/upgrades/talos-upgrade.yaml)
tuppr_k8s=$(sed -n 's/^    version:[[:space:]]*//p' platform/tuppr/upgrades/kubernetes-upgrade.yaml)
[ "$tuppr_talos" = "$talos_version" ] \
  || bad "platform/tuppr/upgrades/talos-upgrade.yaml version '$tuppr_talos' is not talosVersion '$talos_version'"
[ "$tuppr_k8s" = "$k8s_version" ] \
  || bad "platform/tuppr/upgrades/kubernetes-upgrade.yaml version '$tuppr_k8s' is not kubernetesVersion '$k8s_version'"
ok "tuppr versions equal talconfig.yaml ($talos_version, $k8s_version)"

# Generated configs and plaintext secrets must never be committable.
for p in talos/clusterconfig/homelab-homelab-cp-1.yaml talos/clusterconfig/talosconfig \
  talos/talsecret.yaml talos/talosconfig; do
  git check-ignore -q "$p" || bad "$p is not git-ignored"
done
git check-ignore -q talos/talsecret.sops.yaml && bad "talos/talsecret.sops.yaml must stay committable"
ok "git-ignore rules"

exit "$fail"
