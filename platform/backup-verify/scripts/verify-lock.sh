#!/bin/sh
# Weekly test of the version lock on the backup bucket (CronJob
# backup-verify-lock, docs/backups.md#immutable-versions).
#
#   test    (aws-cli image) write _lock-test/weekly twice, try to delete the
#           older version, read the bucket policy. Writes the raw results to
#           $WORK and always exits 0, so `report` runs.
#   report  (restic image: jq, wget) decide and push to the Pushgateway:
#             backup_verify_lock_ok 1   the delete was refused by the bucket
#                                       policy and its deny statement is intact
#             backup_verify_lock_ok 0   the delete succeeded, or the policy or
#                                       its deny statement is missing
#           Anything else (a failed write, an unexpected error) is
#           inconclusive: only the run timestamp is pushed and the Job fails.
#
# The verifier key is allowed DeleteObjectVersion on _lock-test/ (IAM,
# bootstrap/aws-backup), so the bucket policy's deny is the only thing that
# refuses it. The old versions expire with the noncurrent-version lifecycle
# rule (30 days); nothing else can remove them.
set -eu

BUCKET="${BUCKET:-ned-si-homelab-backups}"
KEY="${KEY:-_lock-test/weekly}"
WORK="${WORK:-/work}"
CHECK=lock

phase_test() {
  cd "$WORK"
  date -u +%s > start
  date -u +%FT%TZ > body
  rc=0
  aws s3api put-object --bucket "$BUCKET" --key "$KEY" --body body \
    --query VersionId --output text > v1 2> put.err || rc=$?
  [ "$rc" = 0 ] && { aws s3api put-object --bucket "$BUCKET" --key "$KEY" --body body \
    --query VersionId --output text > v2 2>> put.err || rc=$?; }
  echo "$rc" > put.rc
  if [ "$rc" = 0 ]; then
    rc=0
    aws s3api delete-object --bucket "$BUCKET" --key "$KEY" --version-id "$(cat v1)" \
      > delete.out 2> delete.err || rc=$?
    echo "$rc" > delete.rc
  fi
  rc=0
  aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text \
    > policy.json 2> policy.err || rc=$?
  echo "$rc" > policy.rc
  echo "test phase done"
}

# The deny the lock depends on: Deny, every principal, no condition,
# s3:DeleteObjectVersion on every object of the bucket.
deny_intact() {
  jq -e --arg r "arn:aws:s3:::$BUCKET/*" '
    [.Statement[]
     | select(.Effect == "Deny" and .Condition == null
              and (.Principal == "*"
                   or ((.Principal | type) == "object" and .Principal.AWS == "*"))
              and ([.Action] | flatten | index("s3:DeleteObjectVersion")) != null
              and ([.Resource] | flatten | index($r)) != null)]
    | length > 0' "$WORK/policy.json" > /dev/null 2>&1
}

push_lock() {
  _body="backup_verify_lock_last_run_timestamp_seconds $(date -u +%s)
"
  if [ -n "${1:-}" ]; then
    _body="${_body}backup_verify_lock_ok $1
"
    [ "$1" = 1 ] && _body="${_body}backup_verify_lock_last_success_timestamp_seconds $(date -u +%s)
"
  fi
  wget -q -T 20 -O /dev/null --post-data="$_body" \
    "$PUSHGATEWAY/metrics/job/backup-verify/check/$CHECK/target/$BUCKET" \
    || { log "ERROR: push to $PUSHGATEWAY failed"; return 1; }
}

phase_report() {
  # shellcheck source=platform/backup-verify/scripts/common.sh
  . /scripts/common.sh
  cd "$WORK"
  verdict=""
  if [ "$(cat put.rc 2>/dev/null || echo 1)" != 0 ]; then
    log "INCONCLUSIVE: could not write s3://$BUCKET/$KEY: $(head -c 300 put.err)"
  elif [ "$(cat delete.rc)" = 0 ]; then
    log "BROKEN: DeleteObjectVersion of s3://$BUCKET/$KEY version $(cat v1) succeeded"
    verdict=0
  elif [ "$(cat policy.rc)" != 0 ] && grep -q NoSuchBucketPolicy policy.err; then
    log "BROKEN: the bucket has no policy"
    verdict=0
  elif [ "$(cat policy.rc)" != 0 ]; then
    log "INCONCLUSIVE: cannot read the bucket policy: $(head -c 300 policy.err)"
  elif ! deny_intact; then
    log "BROKEN: no unconditional Deny of s3:DeleteObjectVersion for every principal on arn:aws:s3:::$BUCKET/*"
    verdict=0
  elif grep -q AccessDenied delete.err && grep -q 'explicit deny in a resource-based policy' delete.err; then
    log "OK: DeleteObjectVersion refused by the bucket policy; deny statement intact"
    verdict=1
  else
    log "INCONCLUSIVE: delete refused, but not by the bucket policy: $(head -c 300 delete.err)"
  fi
  push_lock "$verdict"
  [ "$verdict" = 1 ]
}

case "${1:-}" in
  test) phase_test ;;
  report) phase_report ;;
  *) echo "usage: $0 test|report" >&2; exit 64 ;;
esac
