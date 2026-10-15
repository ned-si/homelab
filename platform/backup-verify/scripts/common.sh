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
  _body=$(mktemp)
  {
    echo "backup_verify_success $_ok"
    echo "backup_verify_last_run_timestamp_seconds $_now"
    echo "backup_verify_duration_seconds $((_now - _start))"
    [ "$_ok" = 1 ] && echo "backup_verify_last_success_timestamp_seconds $_now"
    for _m in "$@"; do echo "$_m"; done
  } > "$_body"
  if wget -q -T 20 -O /dev/null --post-file="$_body" \
      "$PUSHGATEWAY/metrics/job/backup-verify/check/$_check/target/$_target"; then
    _rc=0
  else
    log "ERROR: push of $_check/$_target to $PUSHGATEWAY failed"
    _rc=1
  fi
  rm -f "$_body"
  return "$_rc"
}
