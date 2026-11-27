#!/bin/bash
# scripts/ci/coverage-report.sh on a Go profile, a coverage.py JSON, the step
# summary and the floors file (fixtures generated in a temp dir).
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

run_report() { # args... -> "rc|stdout and stderr"
  local rc=0 out
  out=$(bash "$REPO_ROOT/scripts/ci/coverage-report.sh" "$@" 2>&1) || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# a.go:1 (3 statements) runs in the second test binary only; b.go:1 (1) never.
cat >"$tmp/cover.out" <<'EOF'
mode: atomic
example.com/m/a.go:1.1,2.2 3 0
example.com/m/b.go:1.1,2.2 1 0
example.com/m/a.go:1.1,2.2 3 2
example.com/m/b.go:1.1,2.2 1 0
EOF
printf '{"totals": {"covered_lines": 41, "num_statements": 50}}\n' >"$tmp/coverage.json"
: >"$tmp/floors"
export COVERAGE_FLOORS="$tmp/floors"

out=$(run_report go demo "$tmp/cover.out")
expect_eq "duplicate blocks are counted once" "0|coverage demo: 75.0% (3/4 statements)" "$out"

out=$(run_report python py "$tmp/coverage.json")
expect_eq "coverage.py JSON totals" "0|coverage py: 82.0% (41/50 statements)" "$out"

summary=$tmp/summary.md
GITHUB_STEP_SUMMARY=$summary run_report go demo "$tmp/cover.out" >/dev/null
GITHUB_STEP_SUMMARY=$summary run_report python py "$tmp/coverage.json" >/dev/null
expect_eq "summary has one header and a row per run" "| Component | Statement coverage | Statements |
|---|---|---|
| demo | 75.0% | 3/4 |
| py | 82.0% | 41/50 |" "$(cat "$summary")"

printf '# comment\ndemo 80 # trailing\npy 80\n' >"$tmp/floors"
out=$(run_report go demo "$tmp/cover.out")
expect_eq "a floor above the figure fails" "1" "${out%%|*}"
expect_contains "the failure names the floor" "demo is at 75.0%, below its floor of 80%" "$out"

out=$(run_report python py "$tmp/coverage.json")
expect_eq "a floor below the figure passes" "0" "${out%%|*}"

printf 'demo 75\n' >"$tmp/floors"
out=$(run_report go demo "$tmp/cover.out")
expect_eq "a floor equal to the figure passes" "0" "${out%%|*}"

out=$(run_report go other "$tmp/cover.out")
expect_eq "a component without a floor passes" "0" "${out%%|*}"

out=$(run_report go demo "$tmp/missing.out")
expect_eq "a missing file fails" "1" "${out%%|*}"

finish
