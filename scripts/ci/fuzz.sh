#!/bin/bash
# fuzz.sh <seconds per target> -- run every target of tests/fuzz/targets.py
# under Atheris, seeded from tests/fuzz/corpus/<target>/.
#
# New corpus entries go to a copy under $RUNNER_TEMP (or a temp dir), never
# into the checkout. A crash, a failed property, a timeout (10 s per input) or
# an out-of-memory is a finding: the input is printed as base64 to the log and
# to $GITHUB_STEP_SUMMARY. To keep it as a regression, decode it into
# tests/fuzz/corpus/<target>/ with the fix (tests/test_fuzz_corpus.py replays
# it). Exit 0 = no finding, 1 = findings, 64 = usage.
set -uo pipefail

if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <seconds per target>" >&2
  exit 64
fi
secs=$1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="${RUNNER_TEMP:-$(mktemp -d)}/fuzz"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
rm -rf "$work"
mkdir -p "$work"

rc=0
{ echo "### fuzz (${secs} s per target)"; echo; echo "| target | result | runs |"; echo "| --- | --- | --- |"; } >> "$summary"
for t in $(python3 "$ROOT/tests/fuzz/fuzz.py" --list); do
  mkdir -p "$work/corpus/$t" "$work/findings/$t"
  cp "$ROOT/tests/fuzz/corpus/$t/"* "$work/corpus/$t/"
  echo "::group::$t"
  python3 "$ROOT/tests/fuzz/fuzz.py" "$t" -max_total_time="$secs" -timeout=10 -rss_limit_mb=2048 \
    -print_final_stats=1 -artifact_prefix="$work/findings/$t/" "$work/corpus/$t" 2>&1 | tee "$work/$t.log"
  status=${PIPESTATUS[0]}
  echo "::endgroup::"
  runs=$(sed -n 's/^stat::number_of_executed_units: *//p' "$work/$t.log" | tail -1)
  if [ "$status" -eq 0 ]; then
    echo "| $t | ok | ${runs:-?} |" >> "$summary"
    continue
  fi
  rc=1
  echo "::error::fuzz target $t: finding (exit $status)"
  echo "| $t | **finding** (exit $status) | ${runs:-?} |" >> "$summary"
  for f in "$work/findings/$t/"*; do
    [ -f "$f" ] || continue
    b64=$(base64 < "$f" | tr -d '\n')
    echo "$t $(basename "$f"): $b64"
    { echo; echo "\`$t\` \`$(basename "$f")\` (base64):"; echo; echo '```'; echo "$b64"; echo '```'; } >> "$work/findings.md"
  done
done
if [ -f "$work/findings.md" ]; then cat "$work/findings.md" >> "$summary"; fi
exit "$rc"
