#!/bin/bash
# coverage-report.sh go|python <component> <file> -- one statement-coverage
# figure (docs/testing.md, "Coverage").
#
# go: a profile from `go test -coverpkg=./... -coverprofile`. -coverpkg
# repeats each block once per test binary, so a block counts once and is
# covered when any copy ran. python: the JSON of `coverage json`.
#
# Prints `coverage <component>: <pct>% (<covered>/<total> statements)`,
# appends a row to $GITHUB_STEP_SUMMARY when set, and exits 1 when
# ci/coverage-floors.txt (or $COVERAGE_FLOORS) gives the component a floor
# above the figure. Needs awk and, for python, python3.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
floors=${COVERAGE_FLOORS:-$root/ci/coverage-floors.txt}

usage() { echo "usage: coverage-report.sh go|python <component> <file>" >&2; exit 2; }
[ "$#" -eq 3 ] || usage
kind=$1
component=$2
file=$3
[ -f "$file" ] || { echo "coverage-report: $file not found" >&2; exit 1; }

case "$kind" in
  go)
    # <file>:<start>,<end> <statements> <count>
    counts=$(awk '$1 != "mode:" && NF == 3 {
        if (!($1 in stmts)) stmts[$1] = $2
        if ($3 > 0) hit[$1] = 1
      }
      END {
        c = 0; t = 0
        for (b in stmts) { t += stmts[b]; if (b in hit) c += stmts[b] }
        print c, t
      }' "$file")
    ;;
  python)
    counts=$(python3 -c 'import json, sys
t = json.load(open(sys.argv[1]))["totals"]
print(t["covered_lines"], t["num_statements"])' "$file")
    ;;
  *) usage ;;
esac
read -r covered total <<<"$counts"
pct=$(awk -v c="$covered" -v t="$total" 'BEGIN { printf "%.1f", t ? c * 100 / t : 0 }')
echo "coverage $component: $pct% ($covered/$total statements)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  header="| Component | Statement coverage | Statements |"
  if ! grep -qxF "$header" "$GITHUB_STEP_SUMMARY" 2>/dev/null; then
    printf '%s\n|---|---|---|\n' "$header" >>"$GITHUB_STEP_SUMMARY"
  fi
  echo "| $component | $pct% | $covered/$total |" >>"$GITHUB_STEP_SUMMARY"
fi

floor=""
if [ -f "$floors" ]; then
  floor=$(awk -v c="$component" '{ sub(/#.*/, "") } $1 == c { print $2; exit }' "$floors")
fi
if [ -n "$floor" ] && awk -v p="$pct" -v f="$floor" 'BEGIN { exit !(p + 0 < f + 0) }'; then
  echo "coverage-report: FAIL $component is at $pct%, below its floor of $floor% ($floors)" >&2
  exit 1
fi
