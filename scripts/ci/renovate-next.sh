#!/bin/bash
# renovate-next.sh -- rebase the next Renovate pull request, and only that one.
#
# Branch protection on main requires the strict `ci` check, so a pull request
# merges only when it is up to date with main. With `rebaseWhen:
# behind-base-branch`, Renovate rebased every open pull request after each
# merge and CI ran on all of them, although only one can merge next. Now
# Renovate rebases on conflicts only (`rebaseWhen: conflicted`), and this
# script, run by .github/workflows/renovate-next.yaml after each push to main
# and every 30 minutes, ticks the rebase checkbox of one pull request at a
# time. Renovate rebases and signs it, CI runs once, auto-merge merges it, the
# push to main runs this again.
#
# Considered: open, not draft, by Renovate, oldest first. Renovate does not
# always turn GitHub auto-merge on (#837), so this does it for every
# candidate that lacks it. Left alone: the label `no-automerge` (the
# exceptions in .github/renovate.json5, data-store majors), and the label
# `automerge-weekdays` (cilium) outside Monday-Friday 9:00-16:59
# Europe/Zurich, Renovate's automergeSchedule for it. A pull request whose
# `renovate/stability-days` status is pending (minimumReleaseAge) is not
# merged either; it gets one comment saying so, and joins once it passes.
#
#   1. Something is already moving: a rebase is requested (box ticked), or a
#      pull request is up to date with main and its `ci` check is queued or
#      running. Then nothing is done.
#   2. Otherwise the oldest pull request behind main whose `ci` did not fail
#      gets its box ticked. A failed `ci` waits for Renovate's next update or
#      a human; it does not block the others.
#
# Prints one line per auto-merge turned on, then one line, what it did and
# why. Environment: REPO (owner/name), GH (default gh), DRY_RUN (1: decide,
# change nothing), NOW (`<weekday 1-7> <hour>`, default the time in
# Europe/Zurich; for tests). Needs gh and jq.
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
