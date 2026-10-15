#!/bin/sh
# Weekly restore test of Seafile's MariaDB dump, run by CronJob
# backup-verify-mariadb. One script, one phase per container, sharing /work:
#
#   fetch        (restic)   restore seafile-mariadb.sql.gz from the newest
#                           `seafile-mariadb` snapshot (restore --verify)
#   credentials  (kubectl)  write the source's root password to an option file
#   compare      (mariadb)  load the dump into a scratch server on the emptyDir,
#                           count the rows of every table in both databases and
#                           compare them
#   report       (kubectl)  push the result to the Pushgateway; exit 1 on FAIL
#
# Compare rule: the table sets must be identical. A source table that has not
# been written since the dump was taken (UPDATE_TIME older than the dump file,
# server up since before the dump) must have exactly the restored row count.
# A table written since then is listed with both counts and not compared.
# The source is only read, in one READ ONLY transaction.
set -eu
set -f

PHASE=${1:?usage: verify-mariadb.sh fetch|credentials|compare|report}
WORK=${WORK:-/work}
DBS="ccnet_db seafile_db seahub_db"
DUMP="$WORK/dump/dumps/seafile-mariadb.sql.gz"
SRC_HOST=${SRC_HOST:-mariadb.seafile.svc.cluster.local}
TAB=$(printf '\t')

log() { echo "$(date -u +%H:%M:%S) $*"; }
fail() { log "FAIL: $*"; echo "$*" >> "$WORK/FAILED"; exit 0; }

phase_fetch() {
  date -u +%s > "$WORK/start"
  export RESTIC_REPOSITORY="s3:https://s3.eu-central-1.amazonaws.com/ned-si-homelab-backups/seafile/shared"
  restic --no-lock snapshots --json --tag seafile-mariadb --latest 1 > "$WORK/snap.json" \
    || fail "cannot list seafile-mariadb snapshots"
  [ "$(jq length "$WORK/snap.json")" -gt 0 ] || fail "no seafile-mariadb snapshot"
  jq -r '.[0].time' "$WORK/snap.json"
  restic --no-lock restore latest --tag seafile-mariadb --target "$WORK/dump" --verify \
    --include /dumps/seafile-mariadb.sql.gz || fail "restic restore failed"
  [ -s "$DUMP" ] || fail "the restored dump is missing or empty"
  log "dump restored: $(wc -c < "$DUMP" | tr -d ' ') bytes"
}

phase_credentials() {
  [ -f "$WORK/FAILED" ] && exit 0
  pw=$(kubectl -n seafile get secret seafile-db -o jsonpath='{.data.root-password}' | base64 -d) \
    || fail "cannot read Secret seafile/seafile-db"
  [ -n "$pw" ] || fail "Secret seafile/seafile-db has no root-password"
  umask 077
  esc=$(printf '%s' "$pw" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '[client]\nuser=root\npassword="%s"\n' "$esc" > "$WORK/source.cnf"
  unset pw esc
}

# counts <mariadb client args...>: "schema.table<TAB>rows<TAB>updated epoch"
# for every base table, in one READ ONLY transaction.
counts() {
  list="SELECT CONCAT('SELECT ''', TABLE_SCHEMA, '.', TABLE_NAME, ''', COUNT(*), ',
    COALESCE(UNIX_TIMESTAMP(UPDATE_TIME), 0), ' FROM \`', TABLE_SCHEMA, '\`.\`', TABLE_NAME, '\`;')
    FROM information_schema.TABLES
    WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA IN ('ccnet_db', 'seafile_db', 'seahub_db')
    ORDER BY TABLE_SCHEMA, TABLE_NAME"
  mariadb "$@" -N -B -e "$list" > "$WORK/count.sql" || return 1
  [ -s "$WORK/count.sql" ] || return 1
  {
    echo "SET SESSION TRANSACTION READ ONLY;"
    echo "START TRANSACTION WITH CONSISTENT SNAPSHOT;"
    cat "$WORK/count.sql"
    echo "COMMIT;"
  } | mariadb "$@" -N -B > "$WORK/count.out" || return 1
  sort "$WORK/count.out"
}

phase_compare() {
  [ -f "$WORK/FAILED" ] && exit 0
  export TMPDIR="$WORK/tmp"
  mkdir -p "$WORK/db" "$TMPDIR"
  sock="$WORK/mysqld.sock"
  mariadb-install-db --datadir="$WORK/db" --auth-root-authentication-method=normal \
    --skip-test-db --skip-name-resolve > "$WORK/install.log" 2>&1 \
    || { tail -20 "$WORK/install.log"; fail "mariadb-install-db failed"; }
  mariadbd --datadir="$WORK/db" --socket="$sock" --skip-networking --skip-log-bin \
    --pid-file="$WORK/mysqld.pid" --tmpdir="$TMPDIR" --log-error="$WORK/mysqld.log" \
    --innodb-buffer-pool-size=128M &
  i=0
  until mariadb-admin -S "$sock" -u root ping > /dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 60 ] || { tail -20 "$WORK/mysqld.log"; fail "scratch MariaDB did not start"; }
    sleep 1
  done
  local_db() { mariadb -S "$sock" -u root "$@"; }

  t0=$(date -u +%s)
  gzip -dc "$DUMP" | local_db || fail "loading the dump failed"
  log "dump loaded in $(( $(date -u +%s) - t0 )) s"
  dump_ts=$(stat -c %Y "$DUMP")
  for db in $DBS; do
    [ -n "$(local_db -N -B -e "SHOW DATABASES LIKE '$db'")" ] || fail "database $db is not in the dump"
  done

  counts -S "$sock" -u root > "$WORK/restored.tsv" || fail "counting the restored tables failed"
  src() { mariadb --defaults-extra-file="$WORK/source.cnf" -h "$SRC_HOST" --connect-timeout=10 "$@"; }
  src_started=$(src -N -B -e "SELECT UNIX_TIMESTAMP() - VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS
    WHERE VARIABLE_NAME = 'UPTIME'") || fail "cannot reach the source MariaDB"
  counts --defaults-extra-file="$WORK/source.cnf" -h "$SRC_HOST" --connect-timeout=10 \
    > "$WORK/source.tsv" || fail "counting the source tables failed"
  rm -f "$WORK/source.cnf"
  mariadb-admin -S "$sock" -u root shutdown || true

  # A table written after (dump time - 5 min) may differ; the margin covers
  # the time between the start of the dump transaction and the file's mtime.
  cutoff=$((dump_ts - 300))
  awk -F "$TAB" -v cutoff="$cutoff" -v started="$src_started" -v out="$WORK/result.env" '
    FNR == NR { r[$1] = $2; next }
    { s[$1] = $2; u[$1] = $3 }
    END {
      bad = 0; changed = 0; exact = 0; rows = 0; n = 0
      for (t in r) { n++; rows += r[t]; if (!(t in s)) { print "FAIL " t ": only in the restore"; bad++ } }
      for (t in s) {
        if (!(t in r)) { print "FAIL " t ": only in the source"; bad++; continue }
        stable = (started > 0 && started < cutoff && u[t] < cutoff)
        if (!stable) { changed++; print "changed " t ": restored=" r[t] " source=" s[t]; continue }
        exact++
        if (r[t] != s[t]) { print "FAIL " t ": restored=" r[t] " source=" s[t]; bad++ }
      }
      printf "tables=%d rows=%d exact=%d changed=%d failing=%d\n", n, rows, exact, changed, bad
      printf "TABLES=%d\nROWS=%d\nEXACT=%d\nBAD=%d\n", n, rows, exact, bad > out
      exit (bad > 0)
    }' "$WORK/restored.tsv" "$WORK/source.tsv" || fail "row counts differ from the source"
  echo "DUMP_TS=$dump_ts" >> "$WORK/result.env"
}

phase_report() {
  # shellcheck source=platform/backup-verify/scripts/common.sh
  . /scripts/common.sh
  start=$(cat "$WORK/start" 2>/dev/null || date -u +%s)
  if [ -f "$WORK/FAILED" ] || [ ! -f "$WORK/result.env" ]; then
    [ -f "$WORK/FAILED" ] && sed 's/^/FAIL: /' "$WORK/FAILED"
    push_result mariadb seafile 0 "$start"
    exit 1
  fi
  # shellcheck disable=SC1091
  . "$WORK/result.env"
  # shellcheck disable=SC2153 # set by result.env
  push_result mariadb seafile 1 "$start" \
    "backup_verify_tables $TABLES" "backup_verify_rows $ROWS" \
    "backup_verify_snapshot_timestamp_seconds $DUMP_TS"
  log "PASS seafile: $TABLES tables, $ROWS rows, $EXACT compared exactly"
}

case "$PHASE" in
  fetch) phase_fetch ;;
  credentials) phase_credentials ;;
  compare) phase_compare ;;
  report) phase_report ;;
  *) echo "unknown phase $PHASE" >&2; exit 64 ;;
esac
