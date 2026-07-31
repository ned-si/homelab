#!/usr/bin/env bash
# Quiesce the cluster before unplugging it.
#
# WHY THIS SCRIPT EXISTS
#   Pulling power on four nodes with live iSCSI sessions and a running Postgres is
#   how you find out whether your backups work. This shuts things down in
#   dependency order so nothing is mid-write when the disks stop.
#
# ORDER MATTERS AND IS THE OPPOSITE OF STARTUP:
#   1. suspend Argo CD automation   (or it immediately undoes everything below)
#   2. take a final backup          (the last line of defence)
#   3. scale down applications      (stop writers)
#   4. scale down platform          (databases last among the writers)
#   5. leave infrastructure alone   (CNI/CSI must outlive the workloads)
#   6. cordon + drain, then halt the OS
#
# Usage:
#   ./scripts/graceful-shutdown.sh            # interactive, asks before each phase
#   ./scripts/graceful-shutdown.sh --yes      # no prompts
#   ./scripts/graceful-shutdown.sh --skip-backup
set -uo pipefail

ASSUME_YES=0
SKIP_BACKUP=0
for a in "$@"; do
  case "$a" in
    --yes|-y)      ASSUME_YES=1 ;;
    --skip-backup) SKIP_BACKUP=1 ;;
    -h|--help)     sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done

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

step()  { printf '\n\033[36m=== %s ===\033[0m\n' "$*"; }
ok()    { printf '\033[32m  %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m  %s\033[0m\n' "$*"; }
die()   { printf '\033[31m  %s\033[0m\n' "$*" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf '  %s [y/N] ' "$1"
  read -r r
  case "$r" in [yY]*) return 0 ;; *) return 1 ;; esac
}

kubectl version --client >/dev/null 2>&1 || die "kubectl not found"
kubectl get nodes >/dev/null 2>&1 || die "cannot reach the cluster"

# ---------------------------------------------------------------------------
step "0. Pre-flight"
kubectl get nodes -o wide
echo
kubectl get applications -n argocd -o wide 2>/dev/null || warn "Argo CD not reachable"
echo
confirm "Continue with shutdown?" || { echo "aborted"; exit 0; }

# ---------------------------------------------------------------------------
step "1. Suspending Argo CD automation"
# Without this, selfHeal scales every Deployment straight back up as fast as we
# scale it down.
for app in $(kubectl -n argocd get applications -o name 2>/dev/null); do
  kubectl -n argocd patch "$app" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 \
    && ok "suspended ${app#*/}"
done
warn "Automation is OFF. graceful-startup.sh turns it back on."

# ---------------------------------------------------------------------------
if [ "$SKIP_BACKUP" -eq 0 ]; then
  step "2. Final backup before the move"
  if confirm "Trigger an on-demand backup of every database? (recommended)"; then
    ts=$(date +%Y%m%d-%H%M)
    for entry in "${CNPG_CLUSTERS[@]}"; do
      read -r ns cl <<<"$entry"
      kubectl get cluster "$cl" -n "$ns" >/dev/null 2>&1 || continue
      cat <<EOF | kubectl apply -f - >/dev/null && ok "backup requested: $ns/$cl"
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: premove-${cl}-${ts}
  namespace: ${ns}
spec:
  cluster:
    name: ${cl}
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
    done

    echo
    warn "Waiting for backups to complete. This can take a while on a domestic uplink."
    for entry in "${CNPG_CLUSTERS[@]}"; do
      read -r ns cl <<<"$entry"
      name="premove-${cl}-${ts}"
      kubectl get backup "$name" -n "$ns" >/dev/null 2>&1 || continue
      for _ in $(seq 1 120); do
        phase=$(kubectl -n "$ns" get backup "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
        case "$phase" in
          completed) ok "$ns/$name completed"; break ;;
          failed)    die "$ns/$name FAILED -- do not move the hardware until you understand why" ;;
          *)         sleep 15 ;;
        esac
      done
    done
  fi
else
  warn "Skipping backup (--skip-backup)"
fi

# ---------------------------------------------------------------------------
step "3. Scaling down applications"
# Applications first: they are the writers. Stopping them before the databases
# means the databases get a clean, idle shutdown.
for ns in "${APP_NAMESPACES[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  # Record current replica counts so startup can restore them exactly.
  kubectl -n "$ns" get deploy,statefulset -o json 2>/dev/null \
    | jq -r '.items[] | "\(.kind|ascii_downcase)/\(.metadata.name) \(.spec.replicas)"' \
    >>"/tmp/homelab-replicas.txt" 2>/dev/null || true
  kubectl -n "$ns" scale deploy --all --replicas=0 >/dev/null 2>&1 || true
  kubectl -n "$ns" scale statefulset --all --replicas=0 >/dev/null 2>&1 || true
  # Suspend CronJobs so a backup does not start during shutdown.
  kubectl -n "$ns" patch cronjobs --all --type merge \
    -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
  ok "$ns scaled to zero"
done

echo
warn "Waiting for application pods to terminate..."
for ns in "${APP_NAMESPACES[@]}"; do
  kubectl -n "$ns" wait --for=delete pod --all --timeout=300s >/dev/null 2>&1 || true
done
ok "application pods gone"

# ---------------------------------------------------------------------------
step "4. Scaling down platform"
for ns in "${PLATFORM_NAMESPACES[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  kubectl -n "$ns" scale deploy --all --replicas=0 >/dev/null 2>&1 || true
  kubectl -n "$ns" scale statefulset --all --replicas=0 >/dev/null 2>&1 || true
  ok "$ns scaled to zero"
done

step "4b. Shutting down PostgreSQL cleanly"
# CloudNativePG has a `hibernation` annotation that performs an orderly shutdown
# and detaches the volumes. Much safer than scaling the operator away and letting
# the pods be killed.
for entry in "${CNPG_CLUSTERS[@]}"; do
  read -r ns cl <<<"$entry"
  kubectl get cluster "$cl" -n "$ns" >/dev/null 2>&1 || continue
  kubectl -n "$ns" annotate cluster "$cl" \
    cnpg.io/hibernation=on --overwrite >/dev/null 2>&1 \
    && ok "hibernating $ns/$cl"
done

echo
warn "Waiting for database pods to terminate..."
sleep 20
for entry in "${CNPG_CLUSTERS[@]}"; do
  read -r ns cl <<<"$entry"
  kubectl -n "$ns" wait --for=delete pod -l "cnpg.io/cluster=$cl" --timeout=300s >/dev/null 2>&1 || true
done
ok "databases hibernated"

# ---------------------------------------------------------------------------
step "5. Remaining pods outside kube-system"
kubectl get pods -A --field-selector=status.phase=Running \
  | grep -Ev '^(kube-system|argocd|cert-manager|democratic-csi|external-dns|gateway|cnpg-system|NAMESPACE)' \
  || ok "nothing left running"

echo
warn "Infrastructure (Cilium, democratic-csi, cert-manager) is INTENTIONALLY left"
warn "running: the CSI driver must be alive to unmount volumes cleanly during drain."

# ---------------------------------------------------------------------------
step "6. Cordon and drain"
if confirm "Cordon and drain all nodes?"; then
  for n in $(kubectl get nodes -o name); do
    kubectl cordon "${n#node/}" >/dev/null && ok "cordoned ${n#node/}"
  done
  for n in $(kubectl get nodes -o name); do
    node="${n#node/}"
    warn "draining $node"
    # --ignore-daemonsets: Cilium and the CSI node plugin are DaemonSets and must
    # stay until the very end.
    # --delete-emptydir-data: several pods use emptyDir for caches.
    kubectl drain "$node" \
      --ignore-daemonsets \
      --delete-emptydir-data \
      --force \
      --timeout=300s || warn "drain of $node incomplete -- check for stuck pods"
  done
fi

# ---------------------------------------------------------------------------
step "7. Halt the nodes"
cat <<'EOF'
  Everything above is reversible. The next step is not automated, because the
  ORDER of physical shutdown matters and depends on your hardware:

  1. Halt the Kubernetes nodes. From your workstation, for each node:

         ssh nedsi@homelab-w-1.local  sudo shutdown -h now
         ssh nedsi@homelab-cp-3.local sudo shutdown -h now
         ssh nedsi@homelab-cp-2.local sudo shutdown -h now
         ssh nedsi@homelab-cp-1.local sudo shutdown -h now

     Workers first, control plane last, and the node holding the API VIP very
     last -- otherwise you lose the ability to talk to the cluster mid-shutdown.

  2. ONLY THEN shut down TrueNAS. It is serving the iSCSI volumes those nodes
     were using; stopping it first would yank storage out from under them.

         ssh root@192.168.1.228 shutdown -h now

     Wait for it to actually power off. Check the UI or ping it.

  3. Power off the Turing Pi 2 board, then the PSU, then the switch.

  4. Label the cables before you unplug anything. Photograph the back of the
     rack. You will not remember which port the WAN was in.

  Then see docs/runbooks/house-move.md for the other end.
EOF

ok "cluster quiesced"
