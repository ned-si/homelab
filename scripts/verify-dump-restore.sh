#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Prove that a dump from scripts/dump-databases.sh can actually be restored.
#
# A backup nobody has restored is a hypothesis. This turns it into a fact, by
# restoring into a THROWAWAY CloudNativePG cluster in its own namespace and
# comparing the result against the live database, row count by row count.
#
# platform/backup-verify/ does this on a schedule, from S3. This is the version
# that works today, from a local dump, with no bucket and no credentials.
#
# ---------------------------------------------------------------------------
# IT DOES NOT TOUCH THE SOURCE DATABASE.
#
# Every statement issued against the source is a SELECT against catalog views or
# a COUNT(*). The restore happens in a separate namespace, on a separate volume,
# in a separate cluster that is deleted afterwards. The source is used only as
# the thing to compare against.
# ---------------------------------------------------------------------------
#
# USAGE
#   scripts/verify-dump-restore.sh <namespace> <cluster> <dump-file>
#
#   scripts/verify-dump-restore.sh mealie mealie-postgresql \
#       ~/homelab-backups/20260803T230753Z/pg-mealie-mealie-postgresql.dump
#
#   KEEP=1 ...   leave the throwaway cluster running for poking at
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
: "${KUBECONFIG:=$REPO/kubeconfig-homelab}"
export KUBECONFIG

SRC_NS="${1:-}"; SRC_CL="${2:-}"; DUMP="${3:-}"
if [ -z "$SRC_NS" ] || [ -z "$SRC_CL" ] || [ -z "$DUMP" ]; then
  sed -n '/^# USAGE/,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
[ -f "$DUMP" ] || { echo "no such dump: $DUMP" >&2; exit 1; }

NS=backup-restore-test
CL="verify-$(date -u +%H%M%S)"
FAILS=0

say()  { printf '\n\033[36m=== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# SC2329: invoked indirectly, by `trap cleanup EXIT` below.
# shellcheck disable=SC2329
cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    echo
    echo "KEEP=1 -- leaving $NS/$CL in place. Remove it with:"
    echo "  kubectl delete ns $NS"
    return
  fi
  say "cleaning up"
  # Deleting the namespace takes the Cluster, its pod and its PVC with it.
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
  echo "  namespace $NS deleted (async)"
}
trap cleanup EXIT

# --- what are we restoring into? --------------------------------------------
# Derived from the source cluster, not guessed. A dump from PG 16 will not
# restore into a PG 17 server, and the Immich dump additionally needs the image
# that carries its vector extension's shared library.
IMAGE=$(kubectl -n "$SRC_NS" get cluster "$SRC_CL" -o jsonpath='{.spec.imageName}' 2>/dev/null)
PRELOAD=$(kubectl -n "$SRC_NS" get cluster "$SRC_CL" \
            -o jsonpath='{.spec.postgresql.shared_preload_libraries[*]}' 2>/dev/null)
SRC_POD=$(kubectl -n "$SRC_NS" get cluster "$SRC_CL" -o jsonpath='{.status.currentPrimary}' 2>/dev/null)

[ -n "$IMAGE" ]   || { echo "could not read imageName from $SRC_NS/$SRC_CL" >&2; exit 1; }
[ -n "$SRC_POD" ] || { echo "could not find primary for $SRC_NS/$SRC_CL" >&2; exit 1; }

say "plan"
echo "  source:   $SRC_NS/$SRC_CL  (primary $SRC_POD)"
echo "  dump:     $DUMP  ($(du -h "$DUMP" | cut -f1))"
echo "  image:    $IMAGE"
echo "  preload:  ${PRELOAD:-<none>}"
echo "  target:   $NS/$CL  (throwaway)"

# Query helper for the source. Read-only by construction.
src_q() { kubectl -n "$SRC_NS" exec "$SRC_POD" -c postgres -- \
            psql -U postgres -d app -tAc "$1" 2>/dev/null | tr -d '\r'; }
dst_q() { kubectl -n "$NS" exec "${CL}-1" -c postgres -- \
            psql -U postgres -d app -tAc "$1" 2>/dev/null | tr -d '\r'; }

# --- build the throwaway cluster --------------------------------------------
say "creating throwaway cluster"

# Cleanup is asynchronous (deleting a namespace with a PVC in it is not quick),
# so a second run can arrive while the first namespace is still Terminating.
# Creating into a terminating namespace fails with a Forbidden that reads like a
# permissions problem and is not one. Wait it out instead.
if kubectl get ns "$NS" >/dev/null 2>&1; then
  echo "  namespace $NS still exists; waiting for it to go away (up to 5m)..."
  for _ in $(seq 1 150); do
    kubectl get ns "$NS" >/dev/null 2>&1 || break
    sleep 2
  done
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    echo "  namespace $NS did not terminate. Inspect it:" >&2
    kubectl get ns "$NS" -o jsonpath='{.status}' >&2; echo >&2
    kubectl -n "$NS" get all,pvc 2>&1 | sed 's/^/    /' >&2
    exit 1
  fi
  echo "  gone"
fi

kubectl create ns "$NS" >/dev/null 2>&1

preload_yaml=""
if [ -n "$PRELOAD" ]; then
  preload_yaml="  postgresql:
    shared_preload_libraries:"
  for lib in $PRELOAD; do
    preload_yaml="$preload_yaml
      - $lib"
  done
fi

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $CL
  namespace: $NS
  labels:
    homelab.lilalala.com/ephemeral: "true"
spec:
  instances: 1
  imageName: $IMAGE
  storage:
    size: 5Gi
    storageClass: iscsi
  # No spec.backup: this cluster must not archive WAL anywhere.
  bootstrap:
    initdb:
      database: app
      owner: app
$preload_yaml
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
EOF

echo "  waiting for it to come up (up to 10m)..."
if ! kubectl -n "$NS" wait --for=condition=Ready "cluster/$CL" --timeout=10m >/dev/null 2>&1; then
  no "throwaway cluster never became ready"
  kubectl -n "$NS" get pods 2>&1 | sed 's/^/    /'
  kubectl -n "$NS" describe cluster "$CL" 2>&1 | tail -25 | sed 's/^/    /'
  exit 1
fi
ok "throwaway cluster is Ready"

# --- transfer and restore ----------------------------------------------------
# Via /dev/shm: tmpfs, so nothing is written to a disk that matters. /tmp is
# read-only in this image and the node's own disk is already 83% full.
#
# kubectl cp rather than `kubectl exec -i < file`: stdin-redirected exec wedged
# indefinitely during testing, on one database out of seven.
say "transferring the dump"
if ! kubectl -n "$NS" cp "$DUMP" "${CL}-1:/dev/shm/restore.dump" -c postgres >/dev/null 2>&1; then
  no "kubectl cp failed"
  exit 1
fi
remote_sha=$(kubectl -n "$NS" exec "${CL}-1" -c postgres -- \
               sha256sum /dev/shm/restore.dump 2>/dev/null | cut -d' ' -f1)
local_sha=$(shasum -a 256 "$DUMP" | awk '{print $1}')
if [ "$remote_sha" = "$local_sha" ]; then
  ok "dump arrived intact (sha256 matches)"
else
  no "dump corrupted in transfer (local=$local_sha remote=$remote_sha)"
  exit 1
fi

say "restoring"
# --no-owner: the dump's owner is the source's `app` role; recreate objects as
# the target's own owner instead of failing on a role that does not exist here.
# --exit-on-error so a partial restore is a failure, not a warning.
restore_out=$(kubectl -n "$NS" exec "${CL}-1" -c postgres -- \
  pg_restore -U postgres -d app --no-owner --no-privileges --exit-on-error \
    /dev/shm/restore.dump 2>&1)
rc=$?
kubectl -n "$NS" exec "${CL}-1" -c postgres -- rm -f /dev/shm/restore.dump >/dev/null 2>&1

if [ $rc -ne 0 ]; then
  no "pg_restore exited $rc"
  printf '%s\n' "$restore_out" | tail -15 | sed 's/^/    /'
else
  ok "pg_restore completed cleanly"
fi

# --- assertions --------------------------------------------------------------
say "assertion 1: the server answers"
if [ "$(dst_q 'SELECT 1')" = "1" ]; then
  ok "restored server responds"
else
  no "restored server does not respond"
fi

say "assertion 2: table count matches the source"
s_tbl=$(src_q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
d_tbl=$(dst_q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
echo "  source=$s_tbl  restored=$d_tbl"
if [ -n "$d_tbl" ] && [ "$s_tbl" = "$d_tbl" ]; then
  ok "$d_tbl tables"
else
  no "table count differs (an EMPTY restore is the classic silent failure)"
fi

say "assertion 3: row counts match on the 8 largest tables"
# This is the assertion that actually proves data arrived. A schema-only restore
# passes assertion 2 and fails here.
# Ordered by PHYSICAL SIZE, not pg_stat_user_tables.n_live_tup. The latter is a
# statistics estimate that reads 0 until something has ANALYZEd the table, so it
# happily nominates eight empty tables and the assertion proves nothing.
tables=$(src_q "SELECT c.relname
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'public' AND c.relkind = 'r'
                ORDER BY pg_total_relation_size(c.oid) DESC
                LIMIT 8")
if [ -z "$tables" ]; then
  echo "  (source reports no user tables to compare)"
else
  for t in $tables; do
    s_n=$(src_q "SELECT count(*) FROM public.\"$t\"")
    d_n=$(dst_q "SELECT count(*) FROM public.\"$t\"")
    if [ -n "$d_n" ] && [ "$s_n" = "$d_n" ]; then
      ok "$(printf '%-34s %s rows' "$t" "$d_n")"
    else
      no "$(printf '%-34s source=%s restored=%s' "$t" "$s_n" "${d_n:-<error>}")"
    fi
  done
fi

say "assertion 4: every relation is readable"
# Catches corruption that leaves counts intact but pages unreadable.
unreadable=$(kubectl -n "$NS" exec "${CL}-1" -c postgres -- psql -U postgres -d app -tAc "
DO \$\$
DECLARE r record; n bigint;
BEGIN
  FOR r IN SELECT schemaname, tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I', r.schemaname, r.tablename) INTO n;
  END LOOP;
END \$\$;" 2>&1)
if [ -z "$unreadable" ] || ! printf '%s' "$unreadable" | grep -qi 'error'; then
  ok "all relations scanned without error"
else
  no "unreadable relation(s)"
  printf '%s\n' "$unreadable" | head -5 | sed 's/^/    /'
fi

say "assertion 5: extensions match the source"
s_ext=$(src_q "SELECT extname FROM pg_extension ORDER BY extname" | tr '\n' ' ')
d_ext=$(dst_q "SELECT extname FROM pg_extension ORDER BY extname" | tr '\n' ' ')
echo "  source:   $s_ext"
echo "  restored: $d_ext"
if [ "$s_ext" = "$d_ext" ]; then
  ok "extension sets identical"
else
  no "extension sets differ -- an app that needs a missing one will not boot"
fi

# --- verdict -----------------------------------------------------------------
say "verdict"
if [ "$FAILS" -eq 0 ]; then
  echo "  RESTORE VERIFIED: $SRC_NS/$SRC_CL can be rebuilt from this dump."
  exit 0
fi
echo "  $FAILS CHECK(S) FAILED. This dump is NOT a proven backup."
exit 1
