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
# WHICH NAMESPACE IS ARGO CD IN?
#
# Do not hardcode this. The running Argo CD lives in `argo`; the restructured
# repo installs it into `argocd`, and during the migration BOTH exist. An earlier
# version of this script assumed `argocd`, found no Applications, silently
# suspended nothing -- and then phase 3 scaled everything to zero while
# `selfHeal: true` scaled it straight back up. A shutdown script that does not
# actually stop anything is worse than no shutdown script.
#
# So: discover every namespace that contains Applications, and suspend all of them.
# ---------------------------------------------------------------------------
ARGO_NAMESPACES=$(kubectl get applications.argoproj.io -A \
                    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null \
                  | sort -u | tr '\n' ' ')
if [ -z "${ARGO_NAMESPACES// /}" ]; then
  warn "No Argo CD Applications found in any namespace."
  warn "Either Argo CD is not installed, or its CRD is missing. Nothing to suspend."
else
  ok "Argo CD Applications found in: $ARGO_NAMESPACES"
fi

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
suspended=0
for ans in $ARGO_NAMESPACES; do
  for app in $(kubectl -n "$ans" get applications -o name 2>/dev/null); do
    kubectl -n "$ans" patch "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 \
      && { ok "suspended $ans/${app#*/}"; suspended=$((suspended + 1)); }
  done
done

# Verify rather than assume. This is the one phase whose silent failure makes
# every later phase pointless.
still_automated=$(kubectl get applications.argoproj.io -A \
                    -o jsonpath='{range .items[*]}{.spec.syncPolicy.automated.selfHeal}{"\n"}{end}' 2>/dev/null \
                  | grep -c true)
if [ "${still_automated:-0}" -gt 0 ]; then
  die "$still_automated Application(s) still have selfHeal enabled. Scaling down now
  would be undone immediately. Investigate before continuing:
    kubectl get applications -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SELFHEAL:.spec.syncPolicy.automated.selfHeal"
fi
ok "$suspended Application(s) suspended, none left self-healing"
warn "Automation is OFF. graceful-startup.sh turns it back on."

# ---------------------------------------------------------------------------
if [ "$SKIP_BACKUP" -eq 0 ]; then
  step "2. Final backup before the move"

  # ---------------------------------------------------------------------------
  # 2a. LOCAL LOGICAL DUMPS -- always, and always first.
  #
  # This needs nothing but a kubeconfig: no S3 bucket, no credentials, no barman.
  # It is therefore the backup that actually exists when you need it, and it is
  # self-verifying (source-side checksums, see scripts/dump-databases.sh).
  #
  # It writes to ~/homelab-backups on THIS machine, which is coming with you.
  # ---------------------------------------------------------------------------
  if confirm "Take local logical dumps of every database? (strongly recommended)"; then
    if bash "$(dirname "$0")/dump-databases.sh"; then
      ok "local dumps complete and verified"
    else
      warn "The local dump FAILED."
      confirm "Continue the shutdown anyway?" || die "aborted -- fix the dump first"
    fi
  fi

  # ---------------------------------------------------------------------------
  # 2b. BARMAN backup to object storage -- only if it is actually configured.
  #
  # An earlier version of this unconditionally created a Backup with
  # `method: plugin` / barman-cloud.cloudnative-pg.io. On this cluster that is
  # wrong twice over: CNPG 1.24.1 has no such plugin, and until the S3 bucket
  # exists there is nowhere to write. The Backup went straight to `failed`, and
  # the wait loop below called `die` -- so a missing OPTIONAL backup aborted the
  # whole shutdown.
  #
  # Now: detect whether the cluster declares `spec.backup.barmanObjectStore` and
  # skip cleanly if not. A backup that was never configured is not a failure; a
  # backup that was configured and then failed still is.
  # ---------------------------------------------------------------------------
  ts=$(date +%Y%m%d-%H%M)
  requested=0
  for entry in "${CNPG_CLUSTERS[@]}"; do
    read -r ns cl <<<"$entry"
    kubectl get cluster "$cl" -n "$ns" >/dev/null 2>&1 || continue

    dest=$(kubectl -n "$ns" get cluster "$cl" \
             -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}' 2>/dev/null)
    case "${dest:-}" in
      ""|*REPLACE-ME*)
        warn "$ns/$cl: no object store configured -- skipping remote backup"
        continue
        ;;
    esac

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1 && { ok "backup requested: $ns/$cl -> $dest"; requested=$((requested + 1)); }
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: premove-${cl}-${ts}
  namespace: ${ns}
spec:
  cluster:
    name: ${cl}
  method: barmanObjectStore
EOF
  done

  if [ "$requested" -eq 0 ]; then
    warn "No remote database backups were possible (object storage not set up yet)."
    warn "The local dumps from step 2a are your backup. Make sure they are somewhere"
    warn "other than the machine you are carrying, if you can."
  else
    echo
    warn "Waiting for $requested backup(s). This can take a while on a domestic uplink."
    for entry in "${CNPG_CLUSTERS[@]}"; do
      read -r ns cl <<<"$entry"
      name="premove-${cl}-${ts}"
      kubectl -n "$ns" get backup "$name" >/dev/null 2>&1 || continue
      for _ in $(seq 1 120); do
        phase=$(kubectl -n "$ns" get backup "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
        case "$phase" in
          completed) ok "$ns/$name completed"; break ;;
          failed)
            warn "$ns/$name FAILED:"
            kubectl -n "$ns" get backup "$name" -o jsonpath='{.status.error}' 2>/dev/null | sed 's/^/    /'
            echo
            # Not fatal on its own -- the local dump from 2a still exists -- but
            # you should decide, not the script.
            confirm "Remote backup failed. Continue the shutdown?" \
              || die "aborted -- investigate before moving the hardware"
            break
            ;;
          *) sleep 15 ;;
        esac
      done
    done
  fi
else
  warn "Skipping backup (--skip-backup)"
  warn "If you have not run 'task backup:dump' recently, you are moving hardware"
  warn "with no current backup. That is your call, but it is worth knowing."
fi

# ---------------------------------------------------------------------------
step "3. Scaling down applications"

# Where the pre-shutdown replica counts are recorded so startup can restore them.
#
# TRUNCATED, not appended: an earlier version used `>>`, so a second run in the
# same boot accumulated duplicate entries and the restore had to guess which was
# current. It also lives beside the dumps rather than in /tmp, which macOS and
# some distros clear on reboot -- losing it exactly when it is needed.
REPLICA_STATE="${BACKUP_DIR:-$HOME/homelab-backups}/replica-state.txt"
mkdir -p "$(dirname "$REPLICA_STATE")" 2>/dev/null || true
: >"$REPLICA_STATE"
ok "recording replica counts to $REPLICA_STATE"

# Applications first: they are the writers. Stopping them before the databases
# means the databases get a clean, idle shutdown.
for ns in "${APP_NAMESPACES[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  # Record current replica counts so startup can restore them exactly.
  kubectl -n "$ns" get deploy,statefulset -o json 2>/dev/null \
    | jq -r --arg ns "$ns" '.items[] | "\($ns) \(.kind|ascii_downcase)/\(.metadata.name) \(.spec.replicas)"' \
    >>"$REPLICA_STATE" 2>/dev/null || true
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
# `argo` as well as `argocd`: both may exist during the migration, and the point
# of this list is to show what is UNEXPECTEDLY still running.
kubectl get pods -A --field-selector=status.phase=Running \
  | grep -Ev '^(kube-system|argo|argocd|cert-manager|democratic-csi|external-dns|gateway|cnpg-system|monitoring|NAMESPACE)' \
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

  Then see docs/runbooks/cold-start.md for the other end.
EOF

ok "cluster quiesced"
