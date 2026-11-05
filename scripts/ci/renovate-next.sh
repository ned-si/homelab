#!/bin/bash
# renovate-next.sh -- rebase the next Renovate pull request, and only that one.
#
# main requires a strict `ci`, so only an up-to-date pull request merges.
# Renovate rebases on conflicts only (`rebaseWhen: conflicted`); this script,
# run by .github/workflows/renovate-next.yaml after each push to main and
# every 30 minutes, ticks the rebase checkbox of one pull request at a time,
# so CI runs once per merge.
#
# Candidates: open, not draft, by Renovate, oldest first; auto-merge is turned
# on where Renovate did not (#837). Skipped: label `no-automerge`, label
# `automerge-weekdays` outside Monday-Friday 9:00-16:59 Europe/Zurich, and a
# pending `renovate/stability-days` (one comment says so).
#
#   1. A rebase is requested, or an up-to-date pull request's `ci` is queued
#      or running: do nothing.
#   2. Otherwise tick the oldest pull request behind main whose `ci` did not
#      fail.
#
# Paused while RENOVATE_TRAIN_PAUSED ("<pr> <utc time>", set by
# scripts/pr-merge.sh during its merge lock) is younger than PAUSE_STALE_MIN
# (90) minutes; GitHub auto-merge stays as it is (#960).
#
# Prints one line per auto-merge turned on, then one line, what it did
# and why. Environment: REPO (owner/name), GH (default gh), DRY_RUN (1:
# decide, change nothing), RENOVATE_TRAIN_PAUSED (the variable's value),
# PAUSE_STALE_MIN, NOW (`<weekday 1-7> <hour>`, default the time in
# Europe/Zurich) and NOW_EPOCH (default now; both for tests). Needs gh and jq.
set -euo pipefail

: "${REPO:?}"
GH=${GH:-gh}
DRY_RUN=${DRY_RUN:-0}
BOX='- [ ] <!-- rebase-check -->'
TICKED='- [x] <!-- rebase-check -->'

NOW=${NOW:-$(TZ=Europe/Zurich date +'%u %H')}
read -r dow hour <<<"$NOW"
weekdays=false
if [ "$dow" -le 5 ] && [ "$((10#$hour))" -ge 9 ] && [ "$((10#$hour))" -le 16 ]; then weekdays=true; fi

prs=$($GH pr list --repo "$REPO" --author app/renovate --state open --limit 100 \
  --json number,isDraft,autoMergeRequest,createdAt,headRefOid,body,statusCheckRollup,labels,comments)

PAUSED=${RENOVATE_TRAIN_PAUSED:-}
PAUSE_STALE_MIN=${PAUSE_STALE_MIN:-90}
NOW_EPOCH=${NOW_EPOCH:-$(date +%s)}
if [ -n "$PAUSED" ]; then
  read -r pause_pr pause_at _ <<<"$PAUSED"
  # No parseable time (set by hand): paused until deleted.
  since=$(jq -rn --arg t "${pause_at:-}" 'try ($t | fromdateiso8601) catch empty')
  if [ -n "$since" ] && [ $((NOW_EPOCH - since)) -gt $((PAUSE_STALE_MIN * 60)) ]; then
    echo "pause by PR #$pause_pr since $pause_at is older than $PAUSE_STALE_MIN min; ignored"
  else
    echo "paused by pr-merge ($PAUSED); nothing rebased"
    exit 0
  fi
fi
# Waiting for minimumReleaseAge: one comment, then left alone until it passes.
WAIT_MARK='<!-- renovate-next:release-age -->'
for n in $(jq -r --arg m "$WAIT_MARK" '.[]
    | select([.statusCheckRollup[]? | select(.context == "renovate/stability-days" and .state != "SUCCESS")] | length > 0)
    | select([.comments[]?.body | contains($m)] | any | not) | .number' <<<"$prs"); do
  if [ "$DRY_RUN" = 1 ]; then
    echo "#$n: would comment: waiting for its release age (dry run)"
  else
    $GH pr comment "$n" --repo "$REPO" --body "**[automation]** Not mergeable yet: the release is younger than \`minimumReleaseAge\` (.github/renovate.json5), so \`renovate/stability-days\` is pending. The Renovate train (scripts/ci/renovate-next.sh) turns auto-merge on and rebases it once that check passes.
$WAIT_MARK" >/dev/null
    echo "#$n: commented: waiting for its release age"
  fi
done
prs=$(jq '[.[] | select([.statusCheckRollup[]? | select(.context == "renovate/stability-days" and .state != "SUCCESS")] | length == 0)]' <<<"$prs")

prs=$(jq --argjson wd "$weekdays" '[.[] | select(.isDraft | not)
  | ([.labels[]?.name]) as $l
  | select($l | index("no-automerge") | not)
  | select($wd or ($l | index("automerge-weekdays") | not))]' <<<"$prs")

for n in $(jq -r '.[] | select(.autoMergeRequest == null) | .number' <<<"$prs"); do
  if [ "$DRY_RUN" = 1 ]; then
    echo "#$n: would turn auto-merge on (dry run)"
  else
    $GH pr merge "$n" --repo "$REPO" --auto --squash >/dev/null
    echo "#$n: auto-merge turned on"
  fi
done

# One line per candidate, oldest first: number, head SHA, ci state, ticked.
# The ci state is the conclusion when the check completed, else its status
# (QUEUED, IN_PROGRESS, ...), MISSING when there is no `ci` check yet.
rows=$(jq -r --arg ticked "$TICKED" '
  sort_by(.createdAt)[]
  | [ .number, .headRefOid,
      ([.statusCheckRollup[]? | select(.name == "ci")] | last
        | if . == null then "MISSING"
          elif (.conclusion // "") != "" then .conclusion
          else .status // "MISSING" end),
      ((.body // "") | contains($ticked)) ]
  | @tsv' <<<"$prs")

if [ -z "$rows" ]; then
  echo "no Renovate pull request to merge"
  exit 0
fi

behind() { # <sha>: commits on main that the head does not have
  $GH api "repos/$REPO/compare/main...$1" --jq .behind_by
}

next=""
while IFS=$'\t' read -r n sha ci ticked; do
  if [ "$ticked" = true ]; then
    echo "#$n: rebase already requested; waiting"
    exit 0
  fi
  b=$(behind "$sha")
  if [ "$b" = 0 ]; then
    case "$ci" in
      QUEUED | IN_PROGRESS | PENDING | WAITING | REQUESTED | MISSING)
        echo "#$n: up to date, ci $ci; waiting"
        exit 0
        ;;
    esac
  elif [ -z "$next" ] && [ "$ci" != FAILURE ]; then
    next=$n
  fi
done <<<"$rows"

if [ -z "$next" ]; then
  echo "nothing to rebase: every pull request is up to date or failed ci"
  exit 0
fi

body=$(jq -r --argjson n "$next" '.[] | select(.number == $n) | .body // ""' <<<"$prs")
case "$body" in
  *"$BOX"*) ;;
  *)
    echo "#$next: no rebase checkbox in the body; skipped"
    exit 0
    ;;
esac
if [ "$DRY_RUN" = 1 ]; then
  echo "#$next: would request a rebase (dry run)"
  exit 0
fi
# The first box only; jq, not ${body/.../...}, which bash 3.2 and 5 quote
# differently.
jq -n --arg b "$body" --arg box "$BOX" --arg t "$TICKED" \
  '($b | split($box)) as $p | {body: ($p[0] + $t + ($p[1:] | join($box)))}' |
  $GH api -X PATCH "repos/$REPO/pulls/$next" --input - >/dev/null
echo "#$next: rebase requested"
