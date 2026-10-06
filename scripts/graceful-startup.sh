#!/usr/bin/env bash
# Bring the cluster back up after a move or a full shutdown.
#
# Startup order is the REVERSE of shutdown, and the reason each step waits is
# that starting the next one early produces confusing failures:
#
#   1. storage must answer before any pod can attach a volume
#   2. nodes Ready + Cilium healthy before anything is scheduled
#   3. databases before the applications that connect to them
#   4. Argo CD automation LAST, so it does not fight you while you verify
#
# Usage:
#   ./scripts/graceful-startup.sh          # interactive
#   ./scripts/graceful-startup.sh --yes
set -uo pipefail

ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done

NAS_HOST="${NAS_HOST:-192.168.1.228}"
APP_NAMESPACES=(theater immich mealie paperless seafile syncthing)
PLATFORM_NAMESPACES=(keycloak monitoring)
CNPG_CLUSTERS=(
  "immich immich-db"
  "keycloak keycloak-db"
  "mealie mealie-postgresql"
  "theater sonarr-postgresql"
  "theater radarr-postgresql"
  "theater prowlarr-postgresql"
  "theater lidarr-postgresql"
)

# Written by graceful-shutdown.sh. Beside the dumps rather than in /tmp, which is
# cleared on reboot -- i.e. exactly when this script needs it.
REPLICA_STATE="${BACKUP_DIR:-$HOME/homelab-backups}/replica-state.txt"

step() { printf '\n\033[36m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m  %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  %s\033[0m\n' "$*"; }
die()  { printf '\033[31m  %s\033[0m\n' "$*" >&2; exit 1; }
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf '  %s [y/N] ' "$1"; read -r r
  case "$r" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
step "1. Storage must be up FIRST"
cat <<EOF
  Before running any further, confirm by hand:

    [ ] TrueNAS is powered on and its web UI responds
    [ ] the ZFS pool imported cleanly (Storage -> Pools, status ONLINE)
    [ ] the iSCSI service is running
    [ ] the NFS share is exported

  If the NAS address changed, STOP. Update these first, commit, and only then
  continue -- otherwise every PVC will fail to attach and you will be debugging
  the wrong layer:

    infrastructure/nfs-storage/nfs-volumes.yaml            (NFS server)
    infrastructure/secrets/democratic-csi-iscsi.sops.yaml  (iSCSI portal + API)
EOF
printf '\n  Checking %s ... ' "$NAS_HOST"
if ping -c2 -W2 "$NAS_HOST" >/dev/null 2>&1; then ok "reachable"; else
  warn "NOT reachable at $NAS_HOST"
  confirm "Continue anyway?" || exit 1
fi

# ---------------------------------------------------------------------------
step "2. Nodes"
kubectl get nodes >/dev/null 2>&1 || die "cannot reach the API server. Is the control plane up? Has the API VIP changed?"
kubectl get nodes -o wide

echo
warn "Waiting for all nodes Ready (up to 10m)..."
kubectl wait --for=condition=Ready nodes --all --timeout=600s || warn "not all nodes are Ready"

step "2b. Uncordon"
for n in $(kubectl get nodes -o name); do
  kubectl uncordon "${n#node/}" >/dev/null 2>&1 && ok "uncordoned ${n#node/}"
done

# ---------------------------------------------------------------------------
step "3. Cilium / CNI"
warn "Waiting for the Cilium DaemonSet..."
kubectl -n kube-system rollout status ds/cilium --timeout=600s || warn "Cilium not fully ready"

if command -v cilium >/dev/null 2>&1; then
  cilium status --wait --wait-duration 5m || warn "cilium status reports problems"
else
  kubectl -n kube-system get pods -l k8s-app=cilium
fi

echo
warn "Checking the Gateway got its LoadBalancer address back."
kubectl -n gateway get gateway shared -o wide 2>/dev/null || warn "Gateway not found yet"
addr=$(kubectl -n gateway get gateway shared -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
if [ -n "$addr" ]; then
  ok "Gateway address: $addr"
else
  warn "Gateway has no address yet. If this persists, check that the IP pools in"
  warn "infrastructure/cilium/ip-pools.yaml are inside the CURRENT LAN subnet."
fi

# ---------------------------------------------------------------------------
step "4. Storage driver"
kubectl -n democratic-csi get pods 2>/dev/null || warn "democratic-csi namespace missing"
echo
warn "Any PVC stuck Pending here means the iSCSI portal or credentials are wrong."
kubectl get pvc -A 2>/dev/null | grep -v Bound || ok "all PVCs Bound"

# ---------------------------------------------------------------------------
step "5. Databases"
confirm "Wake the PostgreSQL clusters?" || { echo "stopping here"; exit 0; }
for entry in "${CNPG_CLUSTERS[@]}"; do
  read -r ns cl <<<"$entry"
  kubectl get cluster "$cl" -n "$ns" >/dev/null 2>&1 || continue
  kubectl -n "$ns" annotate cluster "$cl" cnpg.io/hibernation=off --overwrite >/dev/null 2>&1 \
    && ok "waking $ns/$cl"
done

echo
warn "Waiting for databases to become Ready (up to 15m)..."
for entry in "${CNPG_CLUSTERS[@]}"; do
  read -r ns cl <<<"$entry"
  kubectl get cluster "$cl" -n "$ns" >/dev/null 2>&1 || continue
  if kubectl -n "$ns" wait --for=condition=Ready "cluster/$cl" --timeout=900s >/dev/null 2>&1; then
    ok "$ns/$cl ready"
  else
    warn "$ns/$cl NOT ready -- check: kubectl -n $ns describe cluster $cl"
  fi
done

# ---------------------------------------------------------------------------
step "6. Platform, then applications"
for ns in "${PLATFORM_NAMESPACES[@]}" ; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  kubectl -n "$ns" scale deploy --all --replicas=1 >/dev/null 2>&1 || true
  kubectl -n "$ns" scale statefulset --all --replicas=1 >/dev/null 2>&1 || true
  ok "$ns scaled up"
done

warn "Waiting for Keycloak before the apps that depend on it..."
kubectl -n keycloak rollout status deploy/keycloak --timeout=600s 2>/dev/null || warn "Keycloak not ready"

# Restore the counts that were actually running, rather than assuming 1.
#
# Everything here happens to be single-replica today, so `--replicas=1` would
# usually be right -- but "usually right" silently scales a future 2-replica
# workload down to 1, and nobody notices until it matters. graceful-shutdown.sh
# records the real numbers; use them when they exist.
if [ -s "$REPLICA_STATE" ]; then
  ok "restoring recorded replica counts from $REPLICA_STATE"
  while read -r ns obj n; do
    [ -z "${ns:-}" ] && continue
    [ "${n:-0}" = "0" ] && continue      # was already scaled to zero on purpose
    kubectl -n "$ns" scale "$obj" --replicas="$n" >/dev/null 2>&1 \
      && ok "  $ns/$obj -> $n"
  done <"$REPLICA_STATE"
else
  warn "No replica state at $REPLICA_STATE -- falling back to --replicas=1."
  warn "That is correct for every current workload, but check anything you expect"
  warn "to run more than one replica of."
  for ns in "${APP_NAMESPACES[@]}"; do
    kubectl get ns "$ns" >/dev/null 2>&1 || continue
    kubectl -n "$ns" scale deploy --all --replicas=1 >/dev/null 2>&1 || true
    kubectl -n "$ns" scale statefulset --all --replicas=1 >/dev/null 2>&1 || true
  done
fi

for ns in "${APP_NAMESPACES[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  kubectl -n "$ns" patch cronjobs --all --type merge \
    -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  ok "$ns cronjobs resumed"
done

# ---------------------------------------------------------------------------
step "7. Certificates and DNS"
kubectl get certificate -A 2>/dev/null || warn "no Certificates found"
echo
warn "If the WAN IP changed, external-dns needs the new value in"
warn "infrastructure/gateway/gateway.yaml. Nothing else."

# ---------------------------------------------------------------------------
step "8. Re-enable Argo CD automation -- LAST"
cat <<'EOF'
  Automation is still OFF (graceful-shutdown.sh disabled it). Leave it off until
  you have verified the cluster by hand, because selfHeal will otherwise start
  reconciling while you are still diagnosing.

  Verify first:
      kubectl get pods -A | grep -Ev 'Running|Completed'
      ./scripts/tls-check.sh

  Then turn automation back on by re-syncing from git, which restores the
  syncPolicy blocks that are committed in the repo:

      argocd app sync root --grpc-web
      argocd app sync layer-infrastructure layer-platform layer-apps --grpc-web

  Confirm:
      kubectl -n argocd get applications -o wide
EOF

if confirm "Re-enable automation NOW (skip manual verification)?"; then
  # Discover the namespace rather than assuming `argocd`. The running Argo CD is
  # in `argo`; the restructured repo uses `argocd`; during the migration both
  # exist. Hardcoding it is what made graceful-shutdown.sh silently suspend
  # nothing.
  #
  # `prune: false` deliberately, whatever the repo says: the first reconcile after
  # a move is not the moment to let Argo delete anything it thinks is surplus.
  restored=0
  for ans in $(kubectl get applications.argoproj.io -A \
                 -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
    for app in root layer-infrastructure layer-platform layer-apps all-apps; do
      kubectl -n "$ans" get application "$app" >/dev/null 2>&1 || continue
      kubectl -n "$ans" patch application "$app" --type merge \
        -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true}}}}' >/dev/null 2>&1 \
        && { ok "automation restored on $ans/$app (prune stays off)"; restored=$((restored + 1)); }
    done
  done
  [ "$restored" -gt 0 ] || warn "no matching Applications found -- restore it by hand"
  warn "Leaf Applications get their real syncPolicy back on the next root sync."
else
  ok "left off -- restore it with the commands above when ready"
fi

step "Done"
echo "  Full post-move checklist: docs/runbooks/cold-start.md"
