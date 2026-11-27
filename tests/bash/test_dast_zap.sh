#!/bin/bash
# scripts/dast-zap.sh against a fake docker: the full scan of one hostname is
# capped (#1319: home.lilalala.com ran over 90 minutes and the run was
# cancelled at the end of its window), and a scan error is retried once.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/out"
cat > "$tmp/bin/docker" <<'EOF'
#!/bin/bash
[ "$1" = pull ] && exit 0
echo "$*" >> "$FAKE/runs.log"
n=$(grep -c . "$FAKE/runs.log")
[ -n "${FAKE_FAIL_FIRST:-}" ] && [ "$n" = 1 ] && exit 3
for a in "$@"; do case "$a" in *.json) echo '{}' > "$FAKE/out/$a" ;; esac; done
EOF
chmod +x "$tmp/bin/docker"
echo home.example.org > "$tmp/hosts"

o=$(PATH="$tmp/bin:$PATH" FAKE="$tmp" ZAP_IMAGE=zap@sha256:x FULL_SCAN=true \
  bash "$REPO_ROOT/scripts/dast-zap.sh" "$tmp/hosts" "$tmp/out" 2>&1)
run=$(cat "$tmp/runs.log")
expect_contains "full scan" "zap-full-scan.py" "$run"
expect_contains "spider capped at 5 minutes" " -m 5 " "$run"
expect_contains "active scan capped at 30 minutes" "scanner.maxScanDurationInMins=30" "$run"
expect_contains "start and passive scan capped" " -T 40 " "$run"
expect_contains "scanned" "home.example.org: scanned" "$o"

: > "$tmp/runs.log"
o=$(PATH="$tmp/bin:$PATH" FAKE="$tmp" FAKE_FAIL_FIRST=1 ZAP_IMAGE=zap@sha256:x \
  bash "$REPO_ROOT/scripts/dast-zap.sh" "$tmp/hosts" "$tmp/out" 2>&1)
expect_eq "a scan error is retried once" 2 "$(grep -c . "$tmp/runs.log")"
expect_contains "and then passes" "home.example.org: scanned" "$o"

finish
