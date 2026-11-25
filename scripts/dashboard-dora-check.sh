#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Recount the DORA figures and the rework rate of the homelab dashboard with
# gh, for the 30 Zurich days ending at --end, by the definitions of
# Requirement 10 in .kiro/specs/homelab-dashboard/requirements.md. It shares
# no code with the collector, so acceptance criteria 18 and 23 compare two
# independent counts.
#
# Time to restore and rework rate also count the firings of the
# `action: human` alerts, read from Prometheus with --prometheus <url> (a
# port-forward). Without it only the rollbacks count, and --compare skips
# the incident figures and the rework rate. An incident counts when it
# started in the window and ended (Requirement 10.4).
#
# USAGE
#   scripts/dashboard-dora-check.sh [--end <RFC 3339>] [--prometheus <url>]
#       prints the figures as JSON; --end defaults to now
#   scripts/dashboard-dora-check.sh --compare <snapshot.json> [--prometheus <url>]
#       takes the end from project.as_of and exits 1 when a count differs by
#       more than one or a median by more than 60 s
#
# Needs gh (authenticated), jq, python3 and, with --prometheus, curl.
# ---------------------------------------------------------------------------
set -euo pipefail

repo=ned-si/homelab
end="" prom="" compare=""
while [ $# -gt 0 ]; do
  case "$1" in
    --end) end=$2; shift 2 ;;
    --prometheus) prom=${2%/}; shift 2 ;;
    --compare) compare=$2; shift 2 ;;
    *) echo "usage: $0 [--end <RFC 3339> | --compare <snapshot.json>] [--prometheus <url>]" >&2; exit 2 ;;
  esac
done
if [ -n "$compare" ]; then
  end=$(jq -er .project.as_of "$compare")
fi

# The window: start is the same Zurich wall time 30 days before the end.
read -r start_s end_s < <(python3 - "${end:-now}" <<'PY'
import datetime, sys, zoneinfo
z = zoneinfo.ZoneInfo("Europe/Zurich")
end = datetime.datetime.now(z) if sys.argv[1] == "now" else datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).astimezone(z)
end = end.replace(microsecond=0)
print(int((end - datetime.timedelta(days=30)).timestamp()), int(end.timestamp()))
PY
)
utc() { jq -nr --argjson t "$1" '$t | todate'; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The merged pull requests, as the collector's GraphQL query reads them.
# shellcheck disable=SC2016 # $q and $endCursor are GraphQL variables
gh api graphql --paginate \
  -f q="repo:$repo is:pr is:merged base:main merged:$(utc "$start_s")..$(utc $((end_s - 1)))" \
  -f query='query($q: String!, $endCursor: String) {
    search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
      issueCount
      pageInfo { hasNextPage endCursor }
      nodes { ... on PullRequest {
        number title createdAt mergedAt
        labels(first: 20) { nodes { name } }
        files(first: 100) { totalCount nodes { path } }
        mergeCommit { oid message status { contexts { context state createdAt } } }
      } }
    }
  }' --jq '.data.search.nodes[]' >"$work/prs.jsonl"

# The paging alerts' firings, in 6-day slices of a 60 s range query.
alerts=skipped
echo '[]' >"$work/firings.json"
if [ -n "$prom" ]; then
  alerts="read"
  : >"$work/series.jsonl"
  s=$start_s
  while [ "$s" -lt "$end_s" ]; do
    e=$((s + 6 * 86400)); [ "$e" -gt "$end_s" ] && e=$end_s
    curl -fsSm 30 "$prom/api/v1/query_range" \
      --data-urlencode 'query=max by (alertname, app, namespace, instance) (ALERTS{alertstate="firing", action="human"})' \
      --data-urlencode "start=$s" --data-urlencode "end=$e" --data-urlencode step=60 |
      jq -c '.data.result[] | {k: (.metric | tostring), t: [.values[][0]]}' >>"$work/series.jsonl"
    s=$((s + 6 * 86400))
  done
  jq -s --argjson end "$end_s" '
    def firings: sort | unique
      | reduce .[] as $t ([]; if length > 0 and ($t - .[-1].e) <= 120 then .[-1].e = $t else . + [{s: $t, e: $t}] end)
      | map(.open = ($end - .e <= 120));
    group_by(.k) | map([.[].t[]] | firings) | add // []' "$work/series.jsonl" >"$work/firings.json"
fi

figures=$(jq -s --argjson start "$start_s" --argjson end "$end_s" --slurpfile firings "$work/firings.json" --arg alerts "$alerts" '
  def ts: sub("\\.[0-9]+"; "") | fromdateiso8601;
  def median: sort | length as $n
    | if $n == 0 then null elif $n % 2 == 1 then .[($n - 1) / 2] else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;
  def labels: [.labels.nodes[].name];
  def deploys: .files.totalCount > (.files.nodes | length)
    or any(.files.nodes[].path; startswith("deploy/") or startswith("clusters/"));
  # The first argocd/* success within 24 h of the merge, or the merge for a
  # change that deploys nothing; null for a deploying merge without one.
  def synced: (.mergedAt | ts) as $m
    | if deploys | not then $m
      else [.mergeCommit.status.contexts[]?
            | select((.context | startswith("argocd/")) and .state == "SUCCESS")
            | .createdAt | ts | select(. >= $m and . - $m <= 86400)] | min end;
  def rollback: (labels | index("auto-rollback")) != null or (.title | test("^revert"; "i"));
  def failed: rollback or (labels | index("fix-forward")) != null;
  def fix: deploys and (.title | test("^fix(\\([^)]*\\))?!?: "));
  def merge: sort_by(.s, .e)
    | reduce .[] as $i ([]; if length > 0 and $i.s <= .[-1].e
        then .[-1].e = ([.[-1].e, $i.e] | max) | .[-1].open = (.[-1].open or $i.open)
        else . + [$i] end);
  . as $prs
  | ($prs | length) as $deploys
  | [$prs[] | synced as $s | select($s != null) | $s - (.createdAt | ts)] as $leads
  | ([$prs[] | select(failed)] | length) as $failed
  | [$prs[] | select(rollback) | synced as $s | select($s != null)
      | ([(.mergeCommit.message // "") | capture("This reverts commit (?<sha>[0-9a-f]{7,40})") | .sha] | first) as $sha
      # A reverted change merged before the window: left out.
      | (if $sha == null then (.createdAt | ts)
         else [$prs[] | select((.mergeCommit.oid // "") | startswith($sha)) | .mergedAt | ts] | first // empty end) as $from
      | ([$from, $s] | min) as $from
      | {s: $from, e: $s, open: false}] as $rollbacks
  | (($rollbacks + $firings[0]) | merge) as $spans
  | [$spans[] | select((.open | not) and .s > $start and .e < $end) | .e - .s] as $restore
  # Rework: rollbacks, fix forwards, and deploying fix merges during an
  # incident or within 24 h after its end, each once.
  | ([$prs[] | (.mergedAt | ts) as $m
      | select(failed or (fix and any($spans[]; $m >= .s and $m <= .e + 86400)))] | length) as $rework
  | {
      window: {start: ($start | todate), end: ($end | todate)},
      alerts: $alerts,
      deploys_30d: $deploys,
      lead_time_seconds: ($leads | median | if . == null then null else round end),
      lead_time_count: ($leads | length),
      failed_changes_30d: $failed,
      change_failure_rate: (if $deploys == 0 then null else ($failed * 1000 / $deploys | round) / 10 end),
      incidents_30d: ($restore | length),
      restore_seconds: ($restore | median | if . == null then null else round end),
      rework_count: $rework,
      rework_rate: (if $deploys == 0 then null else $rework / $deploys end)
    }' "$work/prs.jsonl")

if [ -z "$compare" ]; then
  echo "$figures"
  exit 0
fi

# Counts within one, medians within 60 s; incidents only with the alerts.
jq -nr --argjson f "$figures" --slurpfile s "$compare" '
  ($s[0].project | . + {rework_count: .rework.count?}) as $p
  | [["deploys_30d", 1], ["lead_time_count", 1], ["failed_changes_30d", 1], ["lead_time_seconds", 60]]
    + (if $f.alerts == "read" then [["incidents_30d", 1], ["restore_seconds", 60], ["rework_count", 1]] else [] end)
  | map(. as [$k, $tol] | {figure: $k, dashboard: $p[$k], recount: $f[$k],
      ok: (if $p[$k] == null or $f[$k] == null then $p[$k] == $f[$k] else (($p[$k] - $f[$k]) | fabs) <= $tol end)})
  | (.[] | "\(if .ok then "ok  " else "DIFF" end) \(.figure): dashboard \(.dashboard), recount \(.recount)"),
    (if all(.ok) then "dashboard-dora-check: equal within one pull request and one minute"
     else "dashboard-dora-check: FAIL\n" | halt_error(1) end)'
