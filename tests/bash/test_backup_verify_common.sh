#!/bin/bash
# platform/backup-verify/scripts/common.sh push_result: the metrics reach the
# Pushgateway without a temp file, since some verify containers have no
# writable /tmp (#447).
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/wget" <<FAKE
#!/bin/sh
for a in "\$@"; do
  case "\$a" in --post-data=*) printf '%s' "\${a#--post-data=}" > "$tmp/body" ;; http*) echo "\$a" > "$tmp/url" ;; esac
done
FAKE
chmod +x "$tmp/bin/wget"

set +e
o=$(PATH="$tmp/bin:$PATH" TMPDIR=/nonexistent PUSHGATEWAY=http://pg:9091 sh -c \
  '. "$1"; push_result restore mealie 1 "$(date -u +%s)" "backup_verify_rows 42"' sh \
  "$REPO_ROOT/platform/backup-verify/scripts/common.sh" 2>&1)
rc=$?
set -e
expect_eq "push succeeds without a writable temp dir" 0 "$rc"
expect_eq "no error logged" "" "$o"
expect_eq "to the check's group" "http://pg:9091/metrics/job/backup-verify/check/restore/target/mealie" "$(cat "$tmp/url")"
expect_contains "success pushed" "backup_verify_success 1" "$(cat "$tmp/body")"
expect_contains "last success pushed" "backup_verify_last_success_timestamp_seconds" "$(cat "$tmp/body")"
expect_contains "extra metric pushed" "backup_verify_rows 42" "$(cat "$tmp/body")"

finish
