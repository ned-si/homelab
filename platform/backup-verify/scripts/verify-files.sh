#!/bin/sh
# Weekly restic restore test, run by CronJob backup-verify-files (restic image).
#
# For every line of restic-targets.txt: the newest snapshot with that tag must
# be at most MAX_AGE_HOURS old; its required files and a sample of up to
# SAMPLE_FILES other files (each at most SAMPLE_MAX_BYTES, a different set every
# ISO week) are restored into an emptyDir with `restic restore --verify`, and
# each restored file must exist with exactly the size the snapshot records.
# Required files must also be non-empty.
#
# DATA_CHECK=auto (first Saturday of the month: day <= 7), always or never: also
# run `restic check --read-data-subset=<slice>/<slices>` on every repository in
# restic-data-targets.txt. The slice rotates by month, so <slices> months read
# every pack once.
#
# Read-only: no backup, forget or prune, no lock files. The S3 key is the
# verifier key; the NAS repository is mounted read-only.
set -eu
set -f

# shellcheck source=platform/backup-verify/scripts/common.sh
. /scripts/common.sh

S3_BASE="s3:https://s3.eu-central-1.amazonaws.com/ned-si-homelab-backups"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-72}"
SAMPLE_FILES="${SAMPLE_FILES:-5}"
SAMPLE_MAX_BYTES="${SAMPLE_MAX_BYTES:-67108864}"
DATA_CHECK="${DATA_CHECK:-auto}"
WORK="${WORK:-/work}"
TAB=$(printf '\t')

# Every restic call passes --no-lock: `check` would otherwise take an exclusive
# lock, and a lock left by a killed run blocks the nightly backups.
LOCK="--no-lock"

# repo_args <repository spec>: sets RESTIC_REPOSITORY for s3:<prefix> or
# local:<path>.
repo_args() {
  case "$1" in
    s3:*) RESTIC_REPOSITORY="$S3_BASE/${1#s3:}" ;;
    local:*) RESTIC_REPOSITORY="${1#local:}" ;;
    *) log "unknown repository spec $1"; return 1 ;;
  esac
  export RESTIC_REPOSITORY
}

# Epoch of the newest snapshot time in a `restic snapshots --json` file.
snapshot_epoch() {
  jq -r '[.[].time] | max
    | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$")
    | ((.d + "Z") | fromdateiso8601)
      - (if .z == "Z" then 0
         else ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60)
              * (if .z[0:1] == "-" then -1 else 1 end) end)' "$1"
}

# verify_sample <target> <repository spec> <tag> <required paths, ;-separated>
verify_sample() {
  target=$1 tag=$3 required=$4
  start=$(date -u +%s)
  dir="$WORK/$target"
  rm -rf "$dir" && mkdir -p "$dir/restore"
  repo_args "$2" || return 1
  log "=== $target: $RESTIC_REPOSITORY tag $tag"

  # shellcheck disable=SC2086 # $LOCK is one flag
  if ! restic $LOCK snapshots --json --tag "$tag" --latest 1 > "$dir/snap.json" \
      || [ "$(jq length "$dir/snap.json")" -eq 0 ]; then
    log "FAIL $target: no snapshot with tag $tag, or the repository cannot be read"
    return 1
  fi
  snap_ts=$(snapshot_epoch "$dir/snap.json")
  age_h=$(( ($(date -u +%s) - snap_ts) / 3600 ))
  log "newest snapshot: $(jq -r '[.[].time] | max' "$dir/snap.json") (${age_h} h old)"
  if [ "$age_h" -gt "$MAX_AGE_HOURS" ]; then
    log "FAIL $target: newest snapshot is ${age_h} h old (max $MAX_AGE_HOURS h)"
    return 1
  fi

  # shellcheck disable=SC2086
  restic $LOCK ls --json --tag "$tag" latest > "$dir/ls.json" \
    || { log "FAIL $target: cannot list the snapshot"; return 1; }
  # size<TAB>path of every regular file. @tsv escapes tabs, newlines and
  # backslashes in names; those entries are left out of the sample.
  jq -r 'select(.struct_type == "node" and .type == "file") | [.size, .path] | @tsv' \
    "$dir/ls.json" > "$dir/files.tsv"
  rm -f "$dir/ls.json"
  total=$(wc -l < "$dir/files.tsv" | tr -d ' ')
  [ "$total" -gt 0 ] || { log "FAIL $target: the snapshot holds no regular file"; return 1; }

  : > "$dir/pick.tsv"
  missing=0
  old_ifs=$IFS
  IFS=';'
  for req in $required; do
    IFS=$old_ifs
    [ -n "$req" ] || continue
    line=$(awk -F "$TAB" -v p="$req" '$2 == p { print; exit }' "$dir/files.tsv")
    if [ -z "$line" ]; then
      log "FAIL $target: required file $req is not in the snapshot"
      missing=1
    elif [ "${line%%"$TAB"*}" -eq 0 ]; then
      log "FAIL $target: required file $req is empty in the snapshot"
      missing=1
    else
      printf '%s\n' "$line" >> "$dir/pick.tsv"
    fi
  done
  IFS=$old_ifs
  [ "$missing" -eq 0 ] || return 1

  # The sample: non-empty files up to SAMPLE_MAX_BYTES with no glob characters
  # (restore --include takes patterns), spread over the list and moved every
  # ISO week.
  week=$(( $(date -u +%G) * 53 + $(date -u +%V | sed 's/^0//') ))
  awk -F "$TAB" -v max="$SAMPLE_MAX_BYTES" '$1 > 0 && $1 <= max && $2 !~ /[][*?\\]/' \
    "$dir/files.tsv" > "$dir/cand.tsv"
  awk -v n="$(wc -l < "$dir/cand.tsv" | tr -d ' ')" -v k="$SAMPLE_FILES" -v w="$week" '
    BEGIN {
      if (k > n) k = n
      if (k == 0) exit
      stride = int(n / k); off = (w * 7919) % n
      for (i = 0; i < k; i++) pick[((off + i * stride) % n) + 1] = 1
    }
    pick[FNR]' "$dir/cand.tsv" >> "$dir/pick.tsv"
  sort -u "$dir/pick.tsv" -o "$dir/pick.tsv"

  set --
  while IFS= read -r line; do
    set -- "$@" --include "${line#*"$TAB"}"
  done < "$dir/pick.tsv"
  # shellcheck disable=SC2086
  if ! restic $LOCK restore latest --tag "$tag" --target "$dir/restore" --verify "$@" > "$dir/restore.log" 2>&1; then
    tail -20 "$dir/restore.log"
    log "FAIL $target: restic restore failed"
    return 1
  fi
  tail -2 "$dir/restore.log"

  files=0 bytes=0 bad=0
  while IFS="$TAB" read -r size path; do
    f="$dir/restore$path"
    if [ ! -f "$f" ]; then
      log "FAIL $target: $path was not restored"
      bad=1
      continue
    fi
    got=$(stat -c %s "$f")
    if [ "$got" != "$size" ]; then
      log "FAIL $target: $path restored with $got bytes, snapshot says $size"
      bad=1
      continue
    fi
    files=$((files + 1)) bytes=$((bytes + size))
  done < "$dir/pick.tsv"
  rm -rf "$dir"
  [ "$bad" -eq 0 ] || return 1

  log "PASS $target: $files of $total files restored, $bytes bytes, sizes match"
  VERIFY_METRICS="backup_verify_files $files
backup_verify_bytes $bytes
backup_verify_snapshot_timestamp_seconds $snap_ts"
  VERIFY_START=$start
}

# verify_data <target> <repository spec> <slices>
verify_data() {
  target=$1 slices=$3
  repo_args "$2" || return 1
  month=$(( $(date -u +%Y) * 12 + $(date -u +%m | sed 's/^0//') - 1 ))
  slice=$(( month % slices + 1 ))
  log "=== $target: restic check --read-data-subset=$slice/$slices"
  # shellcheck disable=SC2086
  restic $LOCK check --read-data-subset="$slice/$slices"
}

rc=0
while IFS='|' read -r target repo tag required <&3; do
  case "$target" in ''|'#'*) continue ;; esac
  VERIFY_METRICS="" VERIFY_START=$(date -u +%s)
  if verify_sample "$target" "$repo" "$tag" "$required"; then ok=1; else ok=0; rc=1; fi
  rm -rf "${WORK:?}/$target"
  old_ifs=$IFS
  IFS='
'
  # shellcheck disable=SC2086 # one metric per line
  set -- $VERIFY_METRICS
  IFS=$old_ifs
  push_result restic "$target" "$ok" "$VERIFY_START" "$@" || rc=1
done 3< /scripts/restic-targets.txt

case "$DATA_CHECK" in
  always) run_data=1 ;;
  never) run_data=0 ;;
  *) [ "$(date -u +%d | sed 's/^0//')" -le 7 ] && run_data=1 || run_data=0 ;;
esac
if [ "$run_data" -eq 1 ]; then
  while IFS='|' read -r target repo slices <&3; do
    case "$target" in ''|'#'*) continue ;; esac
    start=$(date -u +%s)
    if verify_data "$target" "$repo" "$slices"; then
      log "PASS $target: data subset readable"
      ok=1
    else
      log "FAIL $target: restic check --read-data-subset reported errors"
      ok=0 rc=1
    fi
    push_result restic-data "$target" "$ok" "$start" || rc=1
  done 3< /scripts/restic-data-targets.txt
fi

if [ "$rc" -eq 0 ]; then log "ALL RESTIC CHECKS PASSED"; else log "ONE OR MORE RESTIC CHECKS FAILED"; fi
exit "$rc"
