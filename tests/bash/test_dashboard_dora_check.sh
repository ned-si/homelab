#!/bin/bash
# scripts/dashboard-dora-check.sh against the fixture the collector's
# TestDORAWindowFixture reads (acceptance criterion 30): a firing that
# crosses the window's start, an open one, a rollback of a change merged
# before the window and the rework boundaries. Fake gh and curl answer from
# the fixture.
set -euo pipefail
# shellcheck source=tests/bash/lib.sh
. "$(dirname "$0")/lib.sh"
fixture="$REPO_ROOT/dashboard/internal/collector/testdata/dora-window.json"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'FAKE'
#!/bin/bash
# The GraphQL search: every pull request of the fixture, one per line.
jq -c '.prs[]' "$FIXTURE"
FAKE
cat >"$tmp/bin/curl" <<'FAKE'
#!/bin/bash
# A range query: the fixture's firings as samples every 60 s in [start, end].
start="" end=""
for a in "$@"; do
  case "$a" in start=*) start=${a#start=} ;; end=*) end=${a#end=} ;; esac
done
jq -c --argjson s "$start" --argjson e "$end" '
  {status: "success", data: {resultType: "matrix", result: [.firings[]
    | (.from | fromdateiso8601) as $f | (.to | fromdateiso8601) as $t
    | {metric: .labels, values: [range($s; $e + 1; 60) | select(. >= $f and . <= $t) | [., "1"]]}
    | select(.values | length > 0)]}}' "$FIXTURE"
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/curl"
export FIXTURE="$fixture" PATH="$tmp/bin:$PATH"

end=$(jq -r .end "$fixture")
got=$("$REPO_ROOT/scripts/dashboard-dora-check.sh" --end "$end" --prometheus http://prometheus.test)
for k in failed_changes_30d incidents_30d restore_seconds rework_count; do
  expect_eq "$k equals the collector's" "$(jq -r ".want.$k" "$fixture")" "$(jq -r ".$k" <<<"$got")"
done
expect_eq "rework_rate is rework over deploys" "0.5555555555555556" "$(jq -r .rework_rate <<<"$got")"
expect_eq "alerts read" "read" "$(jq -r .alerts <<<"$got")"

# --compare against a snapshot with the same figures.
jq -n --arg end "$end" --argjson f "$got" '{project: {as_of: $end, deploys_30d: $f.deploys_30d,
  lead_time_count: $f.lead_time_count, failed_changes_30d: $f.failed_changes_30d,
  lead_time_seconds: $f.lead_time_seconds, incidents_30d: $f.incidents_30d,
  restore_seconds: $f.restore_seconds, rework: {count: $f.rework_count}}}' >"$tmp/snapshot.json"
out=$("$REPO_ROOT/scripts/dashboard-dora-check.sh" --compare "$tmp/snapshot.json" --prometheus http://prometheus.test)
expect_contains "--compare equal" "equal within one pull request" "$out"
expect_contains "--compare checks the rework count" "ok   rework_count" "$out"
jq '.project.rework.count += 2' "$tmp/snapshot.json" >"$tmp/off.json"
if out=$("$REPO_ROOT/scripts/dashboard-dora-check.sh" --compare "$tmp/off.json" --prometheus http://prometheus.test 2>&1); then
  bad "--compare with a rework count off by two exits 0"
else
  expect_contains "--compare flags the rework count" "DIFF rework_count" "$out"
fi
finish
