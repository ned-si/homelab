#!/bin/bash
# components/presync-backup/presync-backup.sh (MODE=cronjob) against a fake
# kubectl: the PreSync hook follows the backup freshness rule (#326). It
# skips when the CronJob succeeded < 24 h ago, backs up when it is older or
# ALWAYS_FRESH is set, and is a no-op on a fresh cluster.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/kubectl" <<'EOF'
#!/bin/sh
echo "kubectl $*" >> "$FAKE/calls.log"
case "$*" in
  "get cronjob/mealie-backup --ignore-not-found -o name") if [ -f "$FAKE/last" ]; then echo cronjob.batch/mealie-backup; fi ;;
  "get cronjob/mealie-backup -o jsonpath={.status.lastSuccessfulTime}") cat "$FAKE/last" ;;
  "delete job"*|"create job"*|"wait"*) ;;
  *) echo "fake kubectl: unexpected: $*" >&2; exit 2 ;;
esac
EOF
# busybox and GNU date read -d "YYYY-MM-DD hh:mm:ss"; BSD date does not.
cat > "$tmp/bin/date" <<'EOF'
#!/bin/sh
if [ "$1" = -u ] && [ "$2" = -d ]; then
  exec python3 -c 'import calendar, sys, time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S")))' "$3"
fi
exec /bin/date "$@"
EOF
chmod +x "$tmp/bin/kubectl" "$tmp/bin/date"

iso() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(sys.argv[1]))))' "$1"; }

# run [VAR=value...]: the hook with these extra environment variables.
run() {
  local o r=0
  : > "$tmp/calls.log"
  o=$(env PATH="$tmp/bin:$PATH" FAKE="$tmp" MODE=cronjob CRONJOB=mealie-backup "$@" \
    sh "$REPO_ROOT/components/presync-backup/presync-backup.sh" 2>&1) || r=$?
  printf 'rc=%s %s' "$r" "$o"
}
backed_up() { grep -c '^kubectl create job presync-mealie-backup --from=cronjob/mealie-backup$' "$tmp/calls.log" || true; }

iso 3600 > "$tmp/last"
o=$(run)
expect_contains "a backup 1 h old is fresh: skip" "rc=0 presync-backup: skip: cronjob/mealie-backup last succeeded" "$o"
expect_eq "no backup Job" 0 "$(backed_up)"

iso $((30 * 3600)) > "$tmp/last"
o=$(run)
expect_contains "a backup 30 h old is stale: back up" "backing up (last success" "$o"
expect_eq "one backup Job" 1 "$(backed_up)"

iso 3600 > "$tmp/last"
o=$(run ALWAYS_FRESH=true)
expect_contains "ALWAYS_FRESH backs up a fresh one" "backing up (always fresh for this app)" "$o"
expect_eq "one backup Job (always fresh)" 1 "$(backed_up)"

rm "$tmp/last"
o=$(run)
expect_contains "no CronJob yet (fresh cluster): no-op" "rc=0 presync-backup: cronjob/mealie-backup not found (fresh cluster): no-op" "$o"
expect_eq "no backup Job on a fresh cluster" 0 "$(backed_up)"

finish
