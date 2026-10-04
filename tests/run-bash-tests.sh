#!/bin/bash
# run-bash-tests.sh -- run every tests/bash/test_*.sh; exit 1 if any fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$HERE"/bash/test_*.sh; do
  echo "== $(basename "$t")"
  if ! bash "$t"; then
    echo "FAILED: $(basename "$t")"
    rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "bash tests: all passed"
exit "$rc"
