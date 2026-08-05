#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Take a local, instant rollback point before a risky change. Delete it after.
#
# This is the "local backup before any major update" step. It is NOT a backup in
# the disaster sense -- the snapshots live on the same TrueNAS pool as the data
# they protect, so a pool loss takes both. It defends against the failure that
# actually happens during an upgrade: a bad migration, a config mistake, an
# application that rewrites data in a format the old version cannot read.
#
# Off-site protection is a different mechanism with a different threat model:
# restic + barman to S3. See docs/backups.md.
#
# ---------------------------------------------------------------------------
# WHY SNAPSHOTS AND NOT A COPY
#
# A VolumeSnapshot on ZFS is copy-on-write: taking one on the 317GB Immich
# library is instant and initially free, and only diverging blocks cost space.
# Copying 317GB before every upgrade would take hours and you would stop doing it.
#
# Verified working on this cluster end to end: snapshot a volume, change the
# source, restore from the snapshot, and the PRE-change content comes back.
#
# ---------------------------------------------------------------------------
# WHAT IT DOES
#   1. `pg_dump` every database          (logical, portable, restorable anywhere)
#   2. VolumeSnapshot every file volume  (instant, local, rollback-in-place)
#   3. prints the exact rollback commands
#
# Databases get a logical dump rather than a volume snapshot because a snapshot of
# a running Postgres is only crash-consistent, and because a dump can be restored
# into a different Postgres version -- which is exactly what a major upgrade needs.
#
# IT DOES NOT ROLL BACK FOR YOU. Rollback destroys the current state, so it is
# printed for you to run deliberately, not automated behind a flag.
#
# USAGE
#   scripts/pre-upgrade-snapshot.sh immich-v3        # take, tagged `immich-v3`
#   scripts/pre-upgrade-snapshot.sh --list
#   scripts/pre-upgrade-snapshot.sh --delete immich-v3   # once the upgrade is good
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
: "${KUBECONFIG:=$REPO/kubeconfig-homelab}"
export KUBECONFIG

LABEL_KEY="homelab.lilalala.com/pre-upgrade"
SNAP_CLASS="${SNAP_CLASS:-iscsi}"

# Volumes worth a rollback point: the ones holding data that is expensive or
# impossible to reproduce. Deliberately NOT the caches, transcode scratch, or
# */config volumes that an app rebuilds on its own.
#
#   namespace  pvc
VOLUMES="
immich     immich-data
paperless  paperless-media
paperless  paperless-data
seafile    seafile-pvc
mealie     mealie-pvc
syncthing  syncthing-pvc
"

usage() { sed -n '/^# USAGE/,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; }

# --- list -------------------------------------------------------------------
if [ "${1:-}" = "--list" ]; then
  echo "Existing pre-upgrade snapshots:"
  kubectl get volumesnapshot -A -l "$LABEL_KEY" \
    -o custom-columns='TAG:.metadata.labels.homelab\.lilalala\.com/pre-upgrade,NS:.metadata.namespace,NAME:.metadata.name,SOURCE:.spec.source.persistentVolumeClaimName,READY:.status.readyToUse,SIZE:.status.restoreSize,AGE:.metadata.creationTimestamp' \
    2>&1
  exit 0
fi

# --- delete -----------------------------------------------------------------
if [ "${1:-}" = "--delete" ]; then
  TAG="${2:-}"
  [ -n "$TAG" ] || { echo "usage: $0 --delete <tag>" >&2; exit 1; }
  echo "Deleting snapshots tagged '$TAG'."
  echo
  echo "Make sure the upgrade is actually good first: once these are gone, the"
  echo "only remaining copy is whatever is in S3 and in ~/homelab-backups."
  echo
  kubectl get volumesnapshot -A -l "$LABEL_KEY=$TAG" \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SIZE:.status.restoreSize' 2>&1
  echo
  printf 'Type the tag again to confirm: '
  read -r confirm
  [ "$confirm" = "$TAG" ] || { echo "Aborted."; exit 1; }

  kubectl get volumesnapshot -A -l "$LABEL_KEY=$TAG" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | while read -r ns name; do
      [ -z "${ns:-}" ] && continue
      printf '  %s/%s -> ' "$ns" "$name"
      kubectl -n "$ns" delete volumesnapshot "$name" >/dev/null 2>&1 && echo deleted || echo FAILED
    done
  echo
  echo "Done. The pg_dump directory under ~/homelab-backups is untouched --"
  echo "delete it by hand when you are ready."
  exit 0
fi

# --- take -------------------------------------------------------------------
TAG="${1:-}"
if [ -z "$TAG" ] || [ "${TAG#-}" != "$TAG" ]; then usage; exit 1; fi
case "$TAG" in
  *[^a-z0-9.-]*) echo "tag must be lowercase alphanumeric, dots and dashes only" >&2; exit 1 ;;
esac

echo "=== pre-upgrade rollback point: $TAG ==="

# Fail early rather than half-way: without the CRDs this cannot work at all.
if ! kubectl get volumesnapshotclass "$SNAP_CLASS" >/dev/null 2>&1; then
  echo >&2
  echo "ERROR: VolumeSnapshotClass '$SNAP_CLASS' not found." >&2
  echo "Snapshot support needs infrastructure/snapshot-controller/ synced, and the" >&2
  echo "democratic-csi Application synced so the chart creates the class." >&2
  exit 1
fi

echo
echo "--- 1. databases (logical dumps) ---"
if ! bash scripts/dump-databases.sh; then
  echo >&2
  echo "ERROR: the database dump failed. Refusing to continue -- a rollback point" >&2
  echo "without the databases is not a rollback point." >&2
  exit 1
fi

echo
echo "--- 2. volume snapshots ---"
failed=0
while read -r ns pvc; do
  [ -z "${ns:-}" ] && continue

  if ! kubectl -n "$ns" get pvc "$pvc" >/dev/null 2>&1; then
    printf '  %-12s %-20s SKIP (no such PVC)\n' "$ns" "$pvc"
    continue
  fi

  snap="preupg-${TAG}-${pvc}"
  snap=$(printf '%.63s' "$snap")

  if kubectl -n "$ns" get volumesnapshot "$snap" >/dev/null 2>&1; then
    printf '  %-12s %-20s exists already\n' "$ns" "$pvc"
    continue
  fi

  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $snap
  namespace: $ns
  labels:
    $LABEL_KEY: $TAG
spec:
  volumeSnapshotClassName: $SNAP_CLASS
  source:
    persistentVolumeClaimName: $pvc
EOF
  printf '  %-12s %-20s requested\n' "$ns" "$pvc"
done <<EOF
$VOLUMES
EOF

echo
echo "--- 3. waiting for snapshots to become ready (up to 10m) ---"
for _ in $(seq 1 120); do
  total=$(kubectl get volumesnapshot -A -l "$LABEL_KEY=$TAG" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get volumesnapshot -A -l "$LABEL_KEY=$TAG" \
            -o jsonpath='{range .items[*]}{.status.readyToUse}{"\n"}{end}' 2>/dev/null \
          | grep -c true)
  [ "$total" -gt 0 ] && [ "$ready" = "$total" ] && break
  sleep 5
done

kubectl get volumesnapshot -A -l "$LABEL_KEY=$TAG" \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SOURCE:.spec.source.persistentVolumeClaimName,READY:.status.readyToUse,SIZE:.status.restoreSize' 2>&1 \
  | sed 's/^/  /'

total=$(kubectl get volumesnapshot -A -l "$LABEL_KEY=$TAG" --no-headers 2>/dev/null | wc -l | tr -d ' ')
ready=$(kubectl get volumesnapshot -A -l "$LABEL_KEY=$TAG" \
          -o jsonpath='{range .items[*]}{.status.readyToUse}{"\n"}{end}' 2>/dev/null | grep -c true)

echo
if [ "$total" -eq 0 ]; then
  echo "ERROR: no snapshots were created." >&2
  exit 1
fi
if [ "$ready" != "$total" ]; then
  echo "WARNING: only $ready of $total snapshots are ready." >&2
  echo "Do NOT start the upgrade until all of them are. Check with:" >&2
  echo "  kubectl describe volumesnapshot -A -l $LABEL_KEY=$TAG" >&2
  failed=1
fi

cat <<EOF

=========================================================================
ROLLBACK POINT '$TAG' -- $ready/$total volumes, plus database dumps.

TO ROLL BACK A VOLUME. Restoring is not in-place: you replace the PVC with a
new one built from the snapshot, reusing the same NAME so the workload finds it.

  # 1. stop whatever writes to it
  kubectl -n <ns> scale deploy/<app> --replicas=0

  # 2. remove the binding. The PV survives -- these volumes are Retain -- so
  #    this leaves an orphaned Released PV to tidy up later, not lost data.
  kubectl -n <ns> delete pvc <pvc>

  # 3. recreate it FROM THE SNAPSHOT, same name, same size
  kubectl -n <ns> apply -f - <<'YAML'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata: { name: <pvc>, namespace: <ns> }
  spec:
    storageClassName: iscsi
    accessModes: [ReadWriteOnce]
    dataSource:
      name: preupg-$TAG-<pvc>
      kind: VolumeSnapshot
      apiGroup: snapshot.storage.k8s.io
    resources: { requests: { storage: <same-size-as-before> } }
  YAML

  # 4. start it again
  kubectl -n <ns> scale deploy/<app> --replicas=1

TO ROLL BACK A DATABASE: restore the dump from ~/homelab-backups into a NEW
cluster and repoint the app. Never restore over a live one.
See docs/backups.md and scripts/verify-dump-restore.sh.

WHEN THE UPGRADE IS CONFIRMED GOOD:
  scripts/pre-upgrade-snapshot.sh --delete $TAG

Leaving snapshots forever is not free: every block that diverges from the
snapshot is retained on the pool, so a large snapshot of a churning volume
quietly grows.
=========================================================================
EOF

exit $failed
