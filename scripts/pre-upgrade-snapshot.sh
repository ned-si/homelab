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
cd "$REPO" || exit 1
: "${KUBECONFIG:=$REPO/kubeconfig-homelab}"
export KUBECONFIG

LABEL_KEY="homelab.lilalala.com/pre-upgrade"
SNAP_CLASS="${SNAP_CLASS:-iscsi}"

# Volumes worth a rollback point: the ones holding data that is expensive or
# impossible to reproduce. Deliberately NOT the caches, transcode scratch, or
# */config volumes that an app rebuilds on its own.
#
# ---------------------------------------------------------------------------
# TWO NAMES HERE WERE WRONG, AND THE SCRIPT SAID SO IN THE QUIETEST POSSIBLE WAY.
#
#   seafile-pvc  ->  seafile-data   (apps/seafile/pvc.yaml)
#   mealie-pvc   ->  mealie-data    (apps/mealie/pvc.yaml)
#
# No PVC exists under either old name, so the loop below printed
# "SKIP (no such PVC)" and carried on. The script then reported a rollback point
# -- correctly counting the snapshots it DID take -- while silently omitting
# Seafile's 100Gi document store and Mealie's uploads.
#
# That is the worst class of bug a backup tool can have: it succeeds, it reports
# a number, and the number is right about the wrong set. The SKIP line is one of
# roughly twenty lines of output and reads like information rather than a
# warning.
#
# The names now come from the manifests. Re-verify after any PVC rename with:
#     kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name
# ---------------------------------------------------------------------------
#
# NOT LISTED, deliberately:
#   seafile-mariadb   a snapshot of a live MariaDB datadir is only
#                     crash-consistent. Step 1 below takes a proper logical dump
#                     with `mariadb-dump --single-transaction`, which is both
#                     consistent AND restorable into a different MariaDB version
#                     -- the thing a major upgrade actually needs. Same
#                     reasoning as for the Postgres clusters.
#   theater/*-config  backed up nightly and consistently by
#                     apps/theater/backup.yaml, and reproducible.
#
#   namespace  pvc
VOLUMES="
immich     immich-data
paperless  paperless-media
paperless  paperless-data
seafile    seafile-data
mealie     mealie-data
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
missing=0
while read -r ns pvc; do
  [ -z "${ns:-}" ] && continue

  # A NAME IN $VOLUMES THAT DOES NOT RESOLVE IS A FAILURE, NOT A NOTE.
  #
  # This used to print `SKIP (no such PVC)` and continue, which is how the
  # seafile-pvc/mealie-pvc typos survived: the script still exited 0 and printed
  # a rollback-point banner. $VOLUMES is a curated list of the volumes that MUST
  # be snapshotted, so an entry that matches nothing means either a rename or a
  # typo, and in both cases the rollback point is not what it claims to be.
  #
  # It is counted separately from `failed` so the final message can distinguish
  # "a snapshot is not ready yet" from "a volume was never even attempted".
  if ! kubectl -n "$ns" get pvc "$pvc" >/dev/null 2>&1; then
    printf '  %-12s %-20s *** NO SUCH PVC -- NOT SNAPSHOTTED ***\n' "$ns" "$pvc"
    missing=$((missing + 1))
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
if [ "$missing" -ne 0 ]; then
  echo >&2
  echo "ERROR: $missing volume(s) in \$VOLUMES do not exist and were NOT" >&2
  echo "snapshotted. This rollback point is INCOMPLETE." >&2
  echo >&2
  echo "Either the PVC was renamed, or the list at the top of this script is" >&2
  echo "wrong. Reconcile it before relying on this:" >&2
  echo "  kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name" >&2
  failed=1
fi

cat <<EOF

=========================================================================
ROLLBACK POINT '$TAG' -- $ready/$total volumes, plus database dumps.

TO ROLL BACK A VOLUME. Restoring is not in-place: you replace the PVC with a
new one built from the snapshot, reusing the same NAME so the workload finds it.

  # 1. stop whatever writes to it
  kubectl -n <ns> scale deploy/<app> --replicas=0

  # 2. CHECK THE PV'S RECLAIM POLICY BEFORE DELETING THE PVC. This is the
  #    step that decides whether the next command is reversible.
  #
  #        kubectl get pv "\$(kubectl -n <ns> get pvc <pvc> \\
  #          -o jsonpath='{.spec.volumeName}')" \\
  #          -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
  #
  #    It MUST print Retain. If it prints Delete, STOP and patch it first:
  #
  #        kubectl patch pv <pv> \\
  #          -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
  #
  #    With Retain, deleting the PVC releases the PV and leaves an orphaned
  #    Released PV to tidy up later. With Delete, it destroys the zvol -- and
  #    the snapshot you are about to restore from is a child of that zvol on
  #    ZFS. See infrastructure/democratic-csi/values-iscsi.yaml.
  kubectl -n <ns> delete pvc <pvc>

  # 3. recreate it FROM THE SNAPSHOT, same name, same size
  #
  #    NOTE THE CLASS: iscsi-retain, NOT iscsi.
  #
  #    This block used to say \`storageClassName: iscsi\`, which was a quiet
  #    downgrade: the existing PVs were patched to Retain by hand on 2026-08-05,
  #    and a PVC recreated on the \`iscsi\` class comes back with a fresh PV
  #    carrying that class's Delete policy. So following a rollback procedure
  #    would silently remove the protection that made the rollback safe -- and
  #    the next rollback would be the one that destroys the data.
  #
  #    A NEW PVC has no immutable field to violate, so naming the class here is
  #    both safe and the only place where the class name does the work.
  kubectl -n <ns> apply -f - <<'YAML'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata: { name: <pvc>, namespace: <ns> }
  spec:
    storageClassName: iscsi-retain
    accessModes: [ReadWriteOnce]
    dataSource:
      name: preupg-$TAG-<pvc>
      kind: VolumeSnapshot
      apiGroup: snapshot.storage.k8s.io
    resources: { requests: { storage: <same-size-as-before> } }
  YAML

  # 3b. Argo CD will now report this PVC as OutOfSync if it is declared in git,
  #     because git says storageClassName: iscsi. DO NOT let selfHeal 'fix' it
  #     -- it cannot, the field is immutable, so the sync simply fails and says
  #     so. Reconcile git to iscsi-retain, or accept the OutOfSync until you do.

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
