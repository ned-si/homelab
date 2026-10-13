#!/bin/bash
#
# Restore one CNPG cluster from its Barman Cloud backups in S3 into a scratch
# namespace, as a NEW Cluster, and compare per-table row counts with the source.
# The source Cluster is only read. The scratch namespace is deleted on every exit.
#
# Usage:
#   aws login --profile homelab --region eu-central-1   # for the verifier key
#   scripts/verify-barman-restore.sh <namespace> <cluster>
#   task backup:verify-barman -- <namespace> <cluster>
#
# How it works:
#   1. Refuses unless <namespace>/<cluster> is a known production cluster and
#      the scratch namespace cnpg-restore-test does not exist.
#   2. L1: row count of every base table of the source database, read-only,
#      in one statement that also returns its time T1 and the current WAL file.
#   3. Waits up to 7.5 min for that WAL file to be archived. archive_timeout
#      is 5 min and only switches a segment that holds WAL, so if it is still
#      not archived, it held nothing at T1: everything visible at T1 is
#      already archived, and a full replay recovers exactly the T1 state.
#   4. Creates cnpg-restore-test with the read-only verifier key
#      (bootstrap/aws-backup output verify_*), ObjectStore cnpg-restore and
#      Cluster restore-<cluster>: same image, preload libraries and size,
#      bootstrapped by recovery from s3://ned-si-homelab-backups/cnpg/<cluster>/:
#      point-in-time to T1 when the segment was archived, else a full replay. It has no spec.plugins, so
#      it never writes to the bucket.
#   5. R: the same counts on the restored database. L2: the source again, for
#      information. The run passes when the table sets are identical and every
#      table has R = L1. For immich-db the restored asset counts are also
#      checked against the floor.
#
# Environment (optional): KUBECONFIG, RESTORE_TIMEOUT (default 45m),
#   IMMICH_FLOOR_IMAGES (48698), IMMICH_FLOOR_VIDEOS (2297).
# Exit codes: 0 PASS, 1 FAIL or error, 64 usage.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SCRATCH=cnpg-restore-test
readonly BUCKET_PATH=s3://ned-si-homelab-backups/cnpg
readonly ENDPOINT=https://s3.eu-central-1.amazonaws.com
readonly PLUGIN=barman-cloud.cloudnative-pg.io
readonly KNOWN="immich/immich-db keycloak/keycloak-db mealie/mealie-postgresql theater/sonarr-postgresql theater/radarr-postgresql theater/lidarr-postgresql theater/prowlarr-postgresql"
RESTORE_TIMEOUT=${RESTORE_TIMEOUT:-45m}
FLOOR_IMAGES=${IMMICH_FLOOR_IMAGES:-48698}
FLOOR_VIDEOS=${IMMICH_FLOOR_VIDEOS:-2297}

log() { echo "$(date -u +%H:%M:%S) $*"; }
die() { log "ERROR: $*"; exit 1; }
k() { kubectl --request-timeout=30s "$@"; }

[ $# -eq 2 ] || { echo "usage: $0 <namespace> <cluster>" >&2; exit 64; }
NS=$1
SRC=$2
case " $KNOWN " in *" $NS/$SRC "*) ;; *) echo "refusing: $NS/$SRC is not one of: $KNOWN" >&2; exit 64 ;; esac
readonly NS SRC
readonly DST="restore-$SRC"
WORK=$(mktemp -d)
readonly WORK
created=0

# Row count of every base table, as "schema.table<TAB>count", sorted.
COUNT_SQL="select table_schema || '.' || table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema') order by 1"

# The same, plus two marker rows from the same snapshot: ~t1 (its time, UTC)
# and ~wal (the WAL file being written).
MARK_SQL="select '~t1', to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS.US') || '+00' union all select '~wal', pg_walfile_name(pg_current_wal_lsn()) union all ($COUNT_SQL)"

psql_ro() { # ns pod db sql out
  kubectl --request-timeout=600s -n "$1" exec "$2" -c postgres -- \
    env PGOPTIONS='-c default_transaction_read_only=on' \
    psql -X -At -F $'\t' -v ON_ERROR_STOP=1 -d "$3" -c "$4" > "$5" \
    || die "query failed on $1/$2"
}
counts() { psql_ro "$1" "$2" "$3" "$COUNT_SQL" "$4"; }

cleanup() {
  local rc=$? pvcs bad
  trap - EXIT
  if [ "$created" -eq 1 ]; then
    log "cleanup: deleting Cluster, ObjectStore and Secret in $SCRATCH"
    k -n "$SCRATCH" delete cluster.postgresql.cnpg.io "$DST" --ignore-not-found --wait=true > /dev/null 2>&1
    k -n "$SCRATCH" delete objectstore.barmancloud.cnpg.io cnpg-restore --ignore-not-found > /dev/null 2>&1
    k -n "$SCRATCH" delete secret cnpg-restore-s3 --ignore-not-found > /dev/null 2>&1
    pvcs=$(k -n "$SCRATCH" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    bad=$(printf '%s\n' "$pvcs" | grep -v '^$' | grep -v "^$DST-" || true)
    if [ -n "$bad" ]; then
      log "cleanup: STOP, unexpected PVCs in $SCRATCH, not deleting the namespace: $bad"
      exit 1
    fi
    k delete namespace "$SCRATCH" --wait=false > /dev/null 2>&1
    for _ in $(seq 1 30); do
      k get namespace "$SCRATCH" > /dev/null 2>&1 || { log "cleanup: $SCRATCH deleted"; break; }
      sleep 10
    done
    k get namespace "$SCRATCH" > /dev/null 2>&1 && { log "cleanup: $SCRATCH still exists after 5 min"; rc=1; }
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# --- 1. preconditions ---------------------------------------------------------
k get namespace "$SCRATCH" > /dev/null 2>&1 && die "namespace $SCRATCH exists; a previous run did not clean up"
k -n "$NS" get cluster.postgresql.cnpg.io "$SRC" -o json > "$WORK/src.json" || die "cannot read $NS/$SRC"
image=$(jq -r '.spec.imageName' "$WORK/src.json")
size=$(jq -r '.spec.storage.size' "$WORK/src.json")
preload=$(jq -c '.spec.postgresql.shared_preload_libraries // []' "$WORK/src.json")
primary=$(jq -r '.status.currentPrimary' "$WORK/src.json")
gen=$(jq -r '.metadata.generation' "$WORK/src.json")
db=$(k -n "$NS" get secret "$SRC-app" -o jsonpath='{.data.dbname}' | base64 -d)
owner=$(k -n "$NS" get secret "$SRC-app" -o jsonpath='{.data.username}' | base64 -d)
[ -n "$db" ] && [ -n "$owner" ] || die "cannot read dbname/username from Secret $NS/$SRC-app"
log "source $NS/$SRC primary=$primary db=$db image=$image size=$size preload=$preload generation=$gen"
window=$(k -n "$NS" get objectstore.barmancloud.cnpg.io cnpg-backup -o json | jq -c --arg c "$SRC" '.status.serverRecoveryWindow[$c] // {}')
log "source recovery window: $window"

id=$("$ROOT/scripts/tofu.sh" bootstrap/aws-backup output -raw verify_access_key_id 2>/dev/null) || die "cannot read the verifier key (aws login?)"
[[ "$id" =~ ^AKIA[A-Z0-9]{16}$ ]] || die "verifier key id has an unexpected shape"

# --- 2. L1 --------------------------------------------------------------------
psql_ro "$NS" "$primary" "$db" "$MARK_SQL" "$WORK/l1m.tsv"
t1=$(awk -F'\t' '$1=="~t1"{print $2}' "$WORK/l1m.tsv")
wal=$(awk -F'\t' '$1=="~wal"{print $2}' "$WORK/l1m.tsv")
grep -v '^~' "$WORK/l1m.tsv" > "$WORK/l1.tsv"
[ -n "$t1" ] && [ -n "$wal" ] || die "no T1/WAL marker in the L1 query"
log "L1 at $t1 (WAL $wal): $(wc -l < "$WORK/l1.tsv" | tr -d ' ') tables, $(awk -F'\t' '{s+=$2} END{print s}' "$WORK/l1.tsv") rows"

# --- 3. wait until the WAL holding T1 is archived ------------------------------
archived() { [ -n "$last" ] && { [ "$last" = "$wal" ] || [[ "$last" > "$wal" ]]; }; }
last=""
for _ in $(seq 1 30); do
  psql_ro "$NS" "$primary" "$db" "select coalesce(last_archived_wal, '') from pg_stat_archiver" "$WORK/arch.txt"
  last=$(cut -c1-24 "$WORK/arch.txt")
  archived && break
  sleep 15
done
if archived; then
  target="      recoveryTarget:
        targetTime: \"$t1\""
  log "last archived WAL $last >= $wal: point-in-time recovery to $t1"
else
  target=""
  log "last archived WAL $last < $wal after 7.5 min: $wal held no WAL at T1; full replay"
fi

# --- 4. restore ---------------------------------------------------------------
created=1
k create namespace "$SCRATCH" > /dev/null || die "cannot create $SCRATCH"
k label namespace "$SCRATCH" pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted > /dev/null
k -n "$SCRATCH" create secret generic cnpg-restore-s3 \
  --from-file=ACCESS_KEY_ID=<(printf '%s' "$id") \
  --from-file=ACCESS_SECRET_KEY=<("$ROOT/scripts/tofu.sh" bootstrap/aws-backup output -raw verify_secret_access_key 2>/dev/null) \
  > /dev/null || die "cannot create the verifier Secret"
unset id
{
  cat <<EOF
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: cnpg-restore
  namespace: $SCRATCH
spec:
  configuration:
    destinationPath: $BUCKET_PATH
    endpointURL: $ENDPOINT
    s3Credentials:
      accessKeyId: {name: cnpg-restore-s3, key: ACCESS_KEY_ID}
      secretAccessKey: {name: cnpg-restore-s3, key: ACCESS_SECRET_KEY}
    wal:
      compression: gzip
  instanceSidecarConfiguration:
    env:
      - {name: AWS_DEFAULT_REGION, value: eu-central-1}
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $DST
  namespace: $SCRATCH
spec:
  instances: 1
  imageName: $image
  postgresql:
    shared_preload_libraries: $preload
  storage:
    storageClass: iscsi
    size: $size
  bootstrap:
    recovery:
      source: origin
      database: $db
      owner: $owner
$target
  externalClusters:
    - name: origin
      plugin:
        name: $PLUGIN
        parameters:
          barmanObjectName: cnpg-restore
          serverName: $SRC
EOF
} > "$WORK/restore.yaml"
k apply -f "$WORK/restore.yaml" > /dev/null || die "cannot create the restore Cluster"
t0=$(date +%s)
log "restoring into $SCRATCH/$DST (timeout $RESTORE_TIMEOUT)"
kubectl -n "$SCRATCH" wait --for=condition=Ready "cluster.postgresql.cnpg.io/$DST" --timeout="$RESTORE_TIMEOUT" > /dev/null \
  || { k -n "$SCRATCH" get cluster,pods,events 2>&1 | tail -20; die "restore did not become Ready"; }
log "restore Ready after $(( $(date +%s) - t0 )) s"

# --- 5. R and L2 --------------------------------------------------------------
dpod=$(k -n "$SCRATCH" get cluster.postgresql.cnpg.io "$DST" -o jsonpath='{.status.currentPrimary}')
counts "$SCRATCH" "$dpod" "$db" "$WORK/r.tsv"
counts "$NS" "$primary" "$db" "$WORK/l2.tsv"
now_gen=$(k -n "$NS" get cluster.postgresql.cnpg.io "$SRC" -o jsonpath='{.metadata.generation}')
[ "$now_gen" = "$gen" ] || die "source generation changed ($gen -> $now_gen)"

# --- 6. compare ---------------------------------------------------------------
verdict=PASS
python3 - "$WORK/l1.tsv" "$WORK/r.tsv" "$WORK/l2.tsv" <<'PY' || verdict=FAIL
import sys
def load(p):
    return {l.split("\t")[0]: int(l.split("\t")[1]) for l in open(p).read().splitlines() if l}
l1, r, l2 = (load(p) for p in sys.argv[1:4])
bad = 0
if set(l1) != set(r) or set(r) != set(l2):
    print("FAIL table sets differ: only source", sorted(set(l1) - set(r)), "only restored", sorted(set(r) - set(l1)))
    bad += 1
for t in sorted(set(l1) & set(r) & set(l2)):
    ok = r[t] == l1[t]
    bad += not ok
    print(f"{'PASS' if ok else 'FAIL'} {t} L1={l1[t]} R={r[t]} L2={l2[t]}")
print(f"tables={len(r)} rows L1={sum(l1.values())} R={sum(r.values())} L2={sum(l2.values())} failing={bad}")
sys.exit(1 if bad else 0)
PY

if [ "$SRC" = immich-db ]; then
  floor=$(kubectl --request-timeout=60s -n "$SCRATCH" exec "$dpod" -c postgres -- \
    psql -X -At -d "$db" -c "select type, count(*) from asset where \"deletedAt\" is null group by type order by 1")
  log "restored Immich assets: $(echo "$floor" | tr '\n' ' ')"
  img=$(echo "$floor" | awk -F'|' '$1=="IMAGE"{print $2}')
  vid=$(echo "$floor" | awk -F'|' '$1=="VIDEO"{print $2}')
  if [ "${img:-0}" -lt "$FLOOR_IMAGES" ] || [ "${vid:-0}" -lt "$FLOOR_VIDEOS" ]; then
    log "FAIL restored Immich below the floor ($FLOOR_IMAGES / $FLOOR_VIDEOS)"
    verdict=FAIL
  fi
fi

log "VERDICT $NS/$SRC: $verdict (restore $(( $(date +%s) - t0 )) s incl. counts)"
[ "$verdict" = PASS ]
