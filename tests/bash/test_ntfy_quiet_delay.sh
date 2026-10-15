#!/bin/bash
# ntfy-quiet-delay.sh at Zurich wall-clock times, summer (CEST) and winter (CET).
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

d() { NOW=$1 "$REPO_ROOT/scripts/ci/ntfy-quiet-delay.sh"; }

# 2026-07-01 (CEST, UTC+2) and 2026-01-15 (CET, UTC+1), UTC epochs.
expect_eq "summer 22:59 Zurich: no delay" "" "$(d 1782939540)"
expect_eq "summer 23:00 Zurich: 540 min" 540 "$(d 1782939600)"
expect_eq "summer 02:30 Zurich: 330 min" 330 "$(d 1782865800)"
expect_eq "summer 07:59 Zurich: 1 min" 1 "$(d 1782885540)"
expect_eq "summer 08:00 Zurich: no delay" "" "$(d 1782885600)"
expect_eq "winter 23:30 Zurich: 510 min" 510 "$(d 1768516200)"
expect_eq "winter 12:00 Zurich: no delay" "" "$(d 1768474800)"

finish
