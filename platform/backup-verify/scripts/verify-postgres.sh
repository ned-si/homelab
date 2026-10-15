#!/bin/sh
# Weekly CNPG restore test, run by CronJob backup-verify-postgres (kubectl
# image, with a psql sidecar in the same pod).
#
# For each line of postgres-targets.txt, one cluster at a time:
#   1. L1: the row count of every table of the source database, read as its
#      owner in a read-only transaction, with the WAL position (LSN) and WAL
#      file of that moment.
#   2. Wait up to 7.5 min for that WAL file to be archived. If it is not, it
#      held no WAL at L1 (archive_timeout is 5 min and switches only a segment
#      with WAL in it), so a full replay recovers exactly the L1 state.
#   3. Create Cluster bv-<source> in backup-verify, bootstrapped by recovery
#      from the source's Barman Cloud archive (ObjectStore verify-source,
#      serverName from the source's plugin parameters), to the L1 LSN, with the
#      source's image, preload libraries and volume size. It has no
#      spec.plugins, so it never writes to the bucket.
#   4. R: the same counts on the restore, as the same role. PASS when the table
#      sets are identical and every table has R = L1. immich-db must also hold
#      at least IMMICH_FLOOR_IMAGES images and IMMICH_FLOOR_VIDEOS videos.
#   5. Delete the Cluster and wait for its volumes to go.
# Production clusters are only read: a `get` of the Cluster and of its -app
# Secret, and SELECTs through its -rw Service.
set -eu
set -f

# shellcheck source=platform/backup-verify/scripts/common.sh
. /scripts/common.sh

NS=backup-verify
SELF=${POD_NAME:?}
RESTORE_TIMEOUT=${RESTORE_TIMEOUT:-30m}
FLOOR_IMAGES=${IMMICH_FLOOR_IMAGES:-0}
FLOOR_VIDEOS=${IMMICH_FLOOR_VIDEOS:-0}
WORK=${WORK:-/tmp/work}
LABEL=homelab.lilalala.com/backup-verify

k() { kubectl --request-timeout=60s "$@"; }

COUNT_SQL="select table_schema || '.' || table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema') order by 1"
MARK_SQL="select '~ts', extract(epoch from now())::bigint::text union all select '~lsn', pg_current_wal_lsn()::text union all select '~wal', pg_walfile_name(pg_current_wal_lsn()) union all ($COUNT_SQL)"

# src_sql <sql>: on the source primary, as the database owner, read-only. psql
# runs in the sidecar; the password goes over stdin, never into an argument.
src_sql() {
  # shellcheck disable=SC2016 # expanded by the sidecar's shell
  printf '%s\n' "$SRC_PW" | kubectl --request-timeout=600s -n "$NS" exec -i "$SELF" -c psql -- \
    sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -q -At -F "|" -v ON_ERROR_STOP=1 "$1" -c "$2"' \
    sh "host=$SRC_HOST port=5432 dbname=$SRC_DB user=$SRC_USER sslmode=require connect_timeout=10 options='-c default_transaction_read_only=on'" "$1"
}

# dst_sql <sql>: on the restored primary, as the same owner role.
dst_sql() {
  kubectl --request-timeout=600s -n "$NS" exec "$DST_POD" -c postgres -- \
    psql -X -q -At -F '|' -v ON_ERROR_STOP=1 -d "$SRC_DB" -c "SET ROLE \"$SRC_USER\"" -c "$1"
}

# delete_restore <cluster>: delete a restore Cluster and wait for its PVCs.
delete_restore() {
  k -n "$NS" delete cluster.postgresql.cnpg.io "$1" --ignore-not-found --wait=true --timeout=5m > /dev/null || true
  i=0
  while [ -n "$(k -n "$NS" get pvc -l "cnpg.io/cluster=$1" -o name)" ]; do
    i=$((i + 1))
    [ "$i" -le 30 ] || { log "ERROR: PVCs of $1 still exist after 5 min"; return 1; }
    sleep 10
  done
}

b64() { printf '%s' "$1" | base64 -d; }

# verify_cluster <namespace> <cluster>; sets VERIFY_METRICS on success.
verify_cluster() {
  src_ns=$1 src=$2
  dst="bv-$src"
  dir="$WORK/$src"
  rm -rf "$dir" && mkdir -p "$dir"
  log "=== $src_ns/$src"

  k -n "$src_ns" get cluster.postgresql.cnpg.io "$src" -o jsonpath='{.spec.imageName}{"\n"}{.spec.storage.size}{"\n"}{.spec.postgresql.shared_preload_libraries}{"\n"}{range .spec.plugins[?(@.isWALArchiver==true)]}{.parameters.serverName}{end}{"\n"}' \
    > "$dir/src.txt" || { log "FAIL $src: cannot read Cluster $src_ns/$src"; return 1; }
  image=$(sed -n 1p "$dir/src.txt")
  size=$(sed -n 2p "$dir/src.txt")
  preload=$(sed -n 3p "$dir/src.txt")
  server=$(sed -n 4p "$dir/src.txt")
  [ -n "$preload" ] || preload="[]"
  [ -n "$server" ] || server=$src
  [ -n "$image" ] && [ -n "$size" ] || { log "FAIL $src: no imageName or storage size on the source"; return 1; }

  app=$(k -n "$src_ns" get secret "$src-app" -o jsonpath='{.data.dbname} {.data.username} {.data.password}') \
    || { log "FAIL $src: cannot read Secret $src_ns/$src-app"; return 1; }
  SRC_DB=$(b64 "${app%% *}")
  app=${app#* }
  SRC_USER=$(b64 "${app%% *}")
  SRC_PW=$(b64 "${app#* }")
  unset app
  [ -n "$SRC_DB" ] && [ -n "$SRC_USER" ] && [ -n "$SRC_PW" ] \
    || { log "FAIL $src: Secret $src_ns/$src-app lacks dbname, username or password"; return 1; }
  SRC_HOST="$src-rw.$src_ns.svc"
  log "source: image=$image size=$size preload=$preload serverName=$server db=$SRC_DB"

  src_sql "$MARK_SQL" > "$dir/l1m" || { log "FAIL $src: cannot query the source"; return 1; }
  ts=$(awk -F'|' '$1 == "~ts" { print $2 }' "$dir/l1m")
  lsn=$(awk -F'|' '$1 == "~lsn" { print $2 }' "$dir/l1m")
  wal=$(awk -F'|' '$1 == "~wal" { print $2 }' "$dir/l1m")
  grep -v '^~' "$dir/l1m" > "$dir/l1"
  [ -n "$ts" ] && [ -n "$lsn" ] && [ -n "$wal" ] || { log "FAIL $src: no LSN marker in the source query"; return 1; }
  log "L1: LSN $lsn, WAL $wal, $(wc -l < "$dir/l1" | tr -d ' ') tables, $(awk -F'|' '{ s += $2 } END { print s + 0 }' "$dir/l1") rows"

  target=""
  i=0
  while [ "$i" -lt 30 ]; do
    last=$(src_sql "select coalesce(last_archived_wal, '') from pg_stat_archiver" | cut -c1-24)
    if [ -n "$last" ] && awk -v a="$last" -v b="$wal" 'BEGIN { exit !(a "" >= b "") }'; then
      target="      recoveryTarget:
        targetLSN: \"$lsn\""
      break
    fi
    i=$((i + 1))
    sleep 15
  done
  if [ -n "$target" ]; then
    log "WAL $wal archived (last $last): recovery to LSN $lsn"
  else
    log "WAL $wal not archived after 7.5 min: it held no WAL at L1, full replay"
  fi

  delete_restore "$dst" || return 1
  cat > "$dir/restore.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $dst
  namespace: $NS
  labels:
    $LABEL: "true"
spec:
  instances: 1
  imageName: $image
  postgresql:
    shared_preload_libraries: $preload
  storage:
    storageClass: iscsi
    size: $size
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
      ephemeral-storage: 256Mi
    limits:
      memory: 2Gi
      ephemeral-storage: 1Gi
  bootstrap:
    recovery:
      source: origin
      database: $SRC_DB
      owner: $SRC_USER
$target
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: verify-source
          serverName: $server
EOF
  k apply -f "$dir/restore.yaml" > /dev/null || { log "FAIL $src: cannot create Cluster $dst"; return 1; }
  t0=$(date -u +%s)
  if ! kubectl -n "$NS" wait --for=condition=Ready "cluster.postgresql.cnpg.io/$dst" --timeout="$RESTORE_TIMEOUT" > /dev/null; then
    k -n "$NS" get cluster.postgresql.cnpg.io,pods -l "cnpg.io/cluster=$dst" 2>&1 | tail -10
    k -n "$NS" logs -l "cnpg.io/cluster=$dst" --all-containers --tail=200 2>/dev/null \
      | grep -E 'FATAL|PANIC|ERROR|recovery' | cut -c1-300 | tail -10
    log "FAIL $src: the restore did not become Ready within $RESTORE_TIMEOUT"
    return 1
  fi
  restore_s=$(( $(date -u +%s) - t0 ))
  DST_POD=$(k -n "$NS" get cluster.postgresql.cnpg.io "$dst" -o jsonpath='{.status.currentPrimary}')
  log "restore Ready after $restore_s s ($DST_POD)"

  dst_sql "$COUNT_SQL" > "$dir/r" || { log "FAIL $src: cannot query the restore"; return 1; }
  awk -F'|' -v out="$dir/sum" '
    FNR == NR { l1[$1] = $2; next }
    { r[$1] = $2 }
    END {
      bad = 0; rows = 0; n = 0
      for (t in l1) if (!(t in r)) { print "FAIL " t ": only in the source"; bad++ }
      for (t in r) {
        n++; rows += r[t]
        if (!(t in l1)) { print "FAIL " t ": only in the restore"; bad++ }
        else if (r[t] != l1[t]) { print "FAIL " t ": source=" l1[t] " restored=" r[t]; bad++ }
      }
      printf "%d %d %d\n", n, rows, bad > out
      exit (bad > 0)
    }' "$dir/l1" "$dir/r" || { log "FAIL $src: row counts differ from the source"; return 1; }
  read -r tables rows _ < "$dir/sum"

  if [ "$src" = immich-db ]; then
    assets=$(dst_sql "select type, count(*) from asset where \"deletedAt\" is null group by type order by 1")
    img=$(echo "$assets" | awk -F'|' '$1 == "IMAGE" { print $2 }')
    vid=$(echo "$assets" | awk -F'|' '$1 == "VIDEO" { print $2 }')
    log "restored Immich assets: ${img:-0} images, ${vid:-0} videos (floor $FLOOR_IMAGES / $FLOOR_VIDEOS)"
    if [ "${img:-0}" -lt "$FLOOR_IMAGES" ] || [ "${vid:-0}" -lt "$FLOOR_VIDEOS" ]; then
      log "FAIL $src: restored Immich is below the floor"
      return 1
    fi
  fi

  log "PASS $src: $tables tables, $rows rows, equal to the source"
  VERIFY_METRICS="backup_verify_tables $tables
backup_verify_rows $rows
backup_verify_restore_seconds $restore_s
backup_verify_snapshot_timestamp_seconds $ts"
}

mkdir -p "$WORK"
for c in $(k -n "$NS" get cluster.postgresql.cnpg.io -l "$LABEL=true" -o name); do
  log "removing leftover $c"
  delete_restore "${c#*/}" || true
done

rc=0
while read -r src_ns src <&3; do
  case "$src_ns" in ''|'#'*) continue ;; esac
  start=$(date -u +%s)
  VERIFY_METRICS=""
  if verify_cluster "$src_ns" "$src"; then ok=1; else ok=0; rc=1; fi
  unset SRC_PW
  delete_restore "bv-$src" || rc=1
  rm -rf "${WORK:?}/$src"
  old_ifs=$IFS
  IFS='
'
  # shellcheck disable=SC2086 # one metric per line
  set -- $VERIFY_METRICS
  IFS=$old_ifs
  push_result postgres "$src" "$ok" "$start" "$@" || rc=1
done 3< /scripts/postgres-targets.txt

if [ "$rc" -eq 0 ]; then log "ALL POSTGRES RESTORES PASSED"; else log "ONE OR MORE POSTGRES RESTORES FAILED"; fi
exit "$rc"
