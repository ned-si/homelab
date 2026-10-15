#!/bin/bash
# talos-upgrade-rehearsal.sh <stage> -- the `talos-upgrade` CI job: rehearse a
# Talos and Kubernetes version change on a throwaway cluster before tuppr
# rolls it out on the nodes.
#
#   plan     whether to rehearse, and the FROM / TO versions (see plan below)
#   create   QEMU cluster (1 control plane, 1 worker) at FROM_TALOS /
#            FROM_KUBERNETES, with the repo's Talos patches, no Flannel and no
#            kube-proxy; Cilium installed meanwhile with the repo's chart
#            version and values, the Gateway API CRDs first
#   smoke    the workload in ci/talos-rehearsal/smoke.yaml, then check it
#   upgrade  `talosctl upgrade` node by node to TO_TALOS (if it differs, or
#            FORCE_TALOS=true), then `talosctl upgrade-k8s --to TO_KUBERNETES`
#   verify   nodes Ready on the target versions, Cilium OK, smoke answers
#   destroy  remove the cluster
#   logs     print node and Cilium state (for a failed run)
#
# QEMU, not Docker: the Docker provisioner cannot run `talosctl upgrade`.
# Each node is a VM with its own disk, so an upgrade installs to the other
# boot slot and reboots, as on the RK1s. The image is the Image Factory's
# empty schematic: the RK1 overlay and iscsi-tools do not boot on x86.
# If the Image Factory does not serve the RK1 installer at TO_TALOS, tuppr's
# pre-pull parks the rollout before any node is drained.
#
# Env: FROM_TALOS FROM_KUBERNETES TO_TALOS TO_KUBERNETES (vX.Y.Z), WORK
# (state dir, default $RUNNER_TEMP/talos-rehearsal), FORCE_TALOS. Needs
# talosctl, kubectl, helm and yq on PATH, qemu and passwordless sudo.
# No secrets: the cluster's keys are generated here and die with the runner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

WORK=${WORK:-${RUNNER_TEMP:-/tmp}/talos-rehearsal}
NAME=rehearsal
CP=10.5.0.2
WORKER=10.5.0.3
NODES="$CP $WORKER"
# Image Factory ID of the empty schematic (no extensions, no overlay).
EMPTY_SCHEMATIC=376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
# talos/patches/talosctl/security-profile.yaml and talos-api-access.yaml are
# applied by scripts/talos-genconfig.sh on the real nodes; same here.
PATCHES_ALL=(talos/patches/sysctls.yaml talos/patches/talosctl/security-profile.yaml ci/talos-rehearsal/no-flannel.yaml)
PATCHES_CP=(talos/patches/kube-proxy.yaml talos/patches/controlplane-metrics.yaml talos/patches/talosctl/controlplane/talos-api-access.yaml)

export TALOSCONFIG="$WORK/talosconfig"
export KUBECONFIG="$WORK/kubeconfig"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "::error::talos-upgrade-rehearsal: $*" >&2; exit 1; }
need() { [ -n "${!1:-}" ] || die "$1 is not set"; }

# Retry "$@" every 5 s for up to $1 seconds.
retry() {
  local limit=$1 start
  shift
  start=$(date +%s)
  until "$@"; do
    [ $(($(date +%s) - start)) -lt "$limit" ] || return 1
    sleep 5
  done
}

talosctl_bin() { command -v talosctl; }

version_of() { # key file
  sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1
}

# plan: decide whether this run rehearses, and between which versions.
# Writes rehearse, force_talos, from_talos, from_kubernetes, to_talos and
# to_kubernetes to $GITHUB_OUTPUT. FROM is talconfig.yaml at BASE (the pull
# request's base, or main), TO is the checkout. A pull request rehearses when
# a version changes or when this script or ci/talos-rehearsal/ changes (then
# Talos is reinstalled at the same version); a manual run always rehearses,
# and INPUT_FROM_TALOS / INPUT_FROM_KUBERNETES override FROM. Pushes to main
# do not: the pull request rehearsed the same change.
plan() {
  need EVENT
  local rehearse=false force=false from_t from_k to_t to_k changed v
  to_t=$(version_of talosVersion talos/talconfig.yaml)
  to_k=$(version_of kubernetesVersion talos/talconfig.yaml)
  from_t=$to_t from_k=$to_k
  if [ "$EVENT" = pull_request ] || [ "$EVENT" = workflow_dispatch ]; then
    need BASE
    git fetch --no-tags --depth=1 origin "$BASE" >/dev/null 2>&1 || die "cannot fetch $BASE"
    git show FETCH_HEAD:talos/talconfig.yaml > "$WORK.base-talconfig.yaml"
    from_t=$(version_of talosVersion "$WORK.base-talconfig.yaml")
    from_k=$(version_of kubernetesVersion "$WORK.base-talconfig.yaml")
    rm -f "$WORK.base-talconfig.yaml"
    changed=$(git diff --name-only FETCH_HEAD HEAD -- scripts/ci/talos-upgrade-rehearsal.sh ci/talos-rehearsal/)
    if [ "$from_t" != "$to_t" ] || [ "$from_k" != "$to_k" ]; then rehearse=true; fi
    if [ -n "$changed" ]; then rehearse=true force=true; fi
  fi
  if [ "$EVENT" = workflow_dispatch ]; then
    rehearse=true force=true
    from_t=${INPUT_FROM_TALOS:-$from_t}
    from_k=${INPUT_FROM_KUBERNETES:-$from_k}
  fi
  for v in "$from_t" "$from_k" "$to_t" "$to_k"; do
    [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a version: '$v'"
  done
  echo "rehearse=$rehearse force_talos=$force talos $from_t -> $to_t, kubernetes $from_k -> $to_k"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "rehearse=$rehearse"
      echo "force_talos=$force"
      echo "from_talos=$from_t"
      echo "from_kubernetes=$from_k"
      echo "to_talos=$to_t"
      echo "to_kubernetes=$to_k"
    } >> "$GITHUB_OUTPUT"
  fi
}

create() {
  need FROM_TALOS; need FROM_KUBERNETES
  mkdir -p "$WORK"
  local args=() p
  for p in "${PATCHES_ALL[@]}"; do args+=(--config-patch "@$p"); done
  for p in "${PATCHES_CP[@]}"; do args+=(--config-patch-controlplanes "@$p"); done

  log "creating the cluster: Talos $FROM_TALOS, Kubernetes $FROM_KUBERNETES"
  # As root (QEMU and the bridge need it), in the background: the command
  # waits for every node to be Ready, which needs the CNI installed below.
  # Its kubeconfig merge goes to root's ~/.kube/config, not $KUBECONFIG.
  # SC2024: the log is meant to belong to the runner user.
  # shellcheck disable=SC2024
  sudo "$(talosctl_bin)" cluster create qemu \
    --name "$NAME" --state "$WORK/state" \
    --presets disk-image \
    --talos-version "$FROM_TALOS" \
    --kubernetes-version "${FROM_KUBERNETES#v}" \
    --controlplanes 1 --workers 1 \
    --memory-controlplanes 3GiB --memory-workers 2GiB \
    --talosconfig-destination "$TALOSCONFIG" \
    "${args[@]}" > "$WORK/create.log" 2>&1 &
  local create_pid=$!

  retry 600 sudo test -s "$TALOSCONFIG" || { cat "$WORK/create.log"; die "no talosconfig after 10 min"; }
  sudo chown "$(id -u):$(id -g)" "$TALOSCONFIG"
  talosctl config endpoint "$CP"
  talosctl config node "$CP"
  log "waiting for the Kubernetes API"
  retry 600 talosctl kubeconfig --force "$KUBECONFIG" >/dev/null 2>&1 || { cat "$WORK/create.log"; die "no kubeconfig"; }
  retry 600 kubectl get --raw /readyz >/dev/null 2>&1 || { cat "$WORK/create.log"; die "Kubernetes API not ready"; }

  log "installing the Gateway API CRDs and Cilium"
  local gw_url
  gw_url=$(grep -o 'https://github.com/kubernetes-sigs/gateway-api/[^ ]*' infrastructure/gateway-api/kustomization.yaml)
  kubectl apply --server-side -f "$gw_url" >/dev/null
  # The same chart version and values file the bootstrap installs
  # (ci/helm-releases.yaml), as on the nodes.
  local repo version values
  repo=$(yq '.releases[] | select(.name == "cilium") | .repo' ci/helm-releases.yaml)
  version=$(yq '.releases[] | select(.name == "cilium") | .version' ci/helm-releases.yaml)
  values=$(yq '.releases[] | select(.name == "cilium") | .values' ci/helm-releases.yaml)
  helm install cilium cilium --repo "$repo" --version "$version" \
    --namespace kube-system -f "$values" --wait --timeout 10m

  log "waiting for talosctl cluster create (every node Ready)"
  if ! wait "$create_pid"; then
    cat "$WORK/create.log"
    die "talosctl cluster create failed"
  fi
  # Root may have rewritten the client config.
  sudo chown "$(id -u):$(id -g)" "$TALOSCONFIG"
  kubectl get nodes -o wide
}

smoke_check() {
  local pod out
  pod=$(kubectl -n smoke get pod -l app=probe -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || return 1
  [ -n "$pod" ] || return 1
  # The probe pod dials the Service by its DNS name: CoreDNS, the Cilium
  # service load balancer and the pod network, reached through the API server.
  out=$(kubectl get --raw "/api/v1/namespaces/smoke/pods/$pod:8080/proxy/dial?request=hostname&host=smoke.smoke.svc.cluster.local&port=80&protocol=http&tries=1" 2>/dev/null) || return 1
  grep -q '"responses":\["smoke-' <<<"$out"
}

smoke() {
  kubectl apply -f ci/talos-rehearsal/smoke.yaml >/dev/null
  kubectl -n smoke rollout status deploy/smoke --timeout=5m
  kubectl -n smoke rollout status deploy/probe --timeout=5m
  retry 120 smoke_check || die "smoke: the Service does not answer"
  log "smoke: the Service answers"
}

node_on_talos() { # ip version
  [ "$(talosctl -n "$1" version --short 2>/dev/null | sed -n 's/^[[:space:]]*Tag:[[:space:]]*//p' | tail -1)" = "$2" ]
}

upgrade() {
  need TO_TALOS; need TO_KUBERNETES
  local n
  if [ "$TO_TALOS" != "${FROM_TALOS:-}" ] || [ "${FORCE_TALOS:-false}" = true ]; then
    for n in $NODES; do
      log "talosctl upgrade $n to $TO_TALOS"
      talosctl -n "$n" upgrade --image "factory.talos.dev/metal-installer/$EMPTY_SCHEMATIC:$TO_TALOS" \
        --wait --timeout 15m --progress plain
      retry 600 node_on_talos "$n" "$TO_TALOS" || die "$n is not on $TO_TALOS after the upgrade"
      retry 600 kubectl wait nodes --all --for=condition=Ready --timeout=10s >/dev/null 2>&1 \
        || die "a node is not Ready after upgrading $n"
    done
  else
    log "Talos stays on $TO_TALOS"
  fi
  log "talosctl upgrade-k8s to $TO_KUBERNETES"
  talosctl -n "$CP" upgrade-k8s --to "${TO_KUBERNETES#v}"
}

verify() {
  need TO_TALOS; need TO_KUBERNETES
  local n fail=0 kubelets
  retry 600 kubectl wait nodes --all --for=condition=Ready --timeout=10s >/dev/null 2>&1 || { echo "::error::nodes not Ready"; fail=1; }
  for n in $NODES; do
    if node_on_talos "$n" "$TO_TALOS"; then log "ok  $n on Talos $TO_TALOS"; else echo "::error::$n is not on Talos $TO_TALOS"; fail=1; fi
  done
  kubelets=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u)
  if [ "$kubelets" = "$TO_KUBERNETES" ]; then log "ok  kubelets on $TO_KUBERNETES"; else echo "::error::kubelet versions: $kubelets"; fail=1; fi
  kubectl -n kube-system rollout status ds/cilium --timeout=5m || fail=1
  if kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief; then
    log "ok  cilium status"
  else
    echo "::error::cilium status is not OK"; fail=1
  fi
  if retry 300 smoke_check; then log "ok  smoke Service answers"; else echo "::error::smoke Service does not answer"; fail=1; fi
  [ "$fail" -eq 0 ] || die "verify failed"
}

logs() {
  kubectl get nodes -o wide || true
  kubectl get pods -A -o wide || true
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status || true
  for n in $NODES; do talosctl -n "$n" services || true; done
  [ -f "$WORK/create.log" ] && tail -50 "$WORK/create.log"
  true
}

destroy() {
  sudo "$(talosctl_bin)" cluster destroy --name "$NAME" --state "$WORK/state" || true
}

case "${1:-}" in
  plan) plan ;;
  create) create ;;
  smoke) smoke ;;
  upgrade) upgrade ;;
  verify) verify ;;
  logs) logs ;;
  destroy) destroy ;;
  *) echo "usage: $0 plan|create|smoke|upgrade|verify|logs|destroy" >&2; exit 64 ;;
esac
