#!/bin/sh
# Sourced by the verify scripts: logging and the Pushgateway push.
#
# Metrics, one group per check and target
# (/metrics/job/backup-verify/check/<check>/target/<target>):
#   backup_verify_success                         1 pass, 0 fail (last run)
#   backup_verify_last_run_timestamp_seconds      end of the last run
#   backup_verify_last_success_timestamp_seconds  end of the last passing run;
#                                                 not pushed on a failure, so
#                                                 the previous value stays
#   backup_verify_duration_seconds                length of the last run
#   plus the check's own figures (rows, tables, files, bytes, snapshot time).

PUSHGATEWAY="${PUSHGATEWAY:-http://pushgateway.backup-verify.svc:9091}"

log() { echo "$(date -u +%H:%M:%S) $*"; }

# push <check> <target> <ok: 1|0> <start epoch> [metric lines...]
push_result() {
  _check=$1 _target=$2 _ok=$3 _start=$4
  shift 4
  _now=$(date -u +%s)
  # The body is built in memory: some containers have no writable /tmp.
  _body="backup_verify_success $_ok
backup_verify_last_run_timestamp_seconds $_now
backup_verify_duration_seconds $((_now - _start))
"
  [ "$_ok" = 1 ] && _body="${_body}backup_verify_last_success_timestamp_seconds $_now
"
  for _m in "$@"; do
    _body="$_body$_m
"
  done
  if wget -q -T 20 -O /dev/null --post-data="$_body" \
      "$PUSHGATEWAY/metrics/job/backup-verify/check/$_check/target/$_target"; then
    return 0
  fi
  log "ERROR: push of $_check/$_target to $PUSHGATEWAY failed"
  return 1
}
