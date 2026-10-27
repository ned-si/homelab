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
# Considered: open, not draft, by Renovate, with auto-merge on (the pull
# requests that wait for a human, cilium for one, are left alone). Oldest
# first.
#
#   1. Something is already moving: a rebase is requested (box ticked), or a
#      pull request is up to date with main and its `ci` check is queued or
#      running. Then nothing is done.
#   2. Otherwise the oldest pull request behind main whose `ci` did not fail
#      gets its box ticked. A failed `ci` waits for Renovate's next update or
#      a human; it does not block the others.
#
# Prints one line, what it did and why. Environment: REPO (owner/name),
# GH (default gh), DRY_RUN (1: decide, change nothing). Needs gh and jq.
set -euo pipefail

: "${REPO:?}"
GH=${GH:-gh}
DRY_RUN=${DRY_RUN:-0}
BOX='- [ ] <!-- rebase-check -->'
TICKED='- [x] <!-- rebase-check -->'

prs=$($GH pr list --repo "$REPO" --author app/renovate --state open --limit 100 \
  --json number,isDraft,autoMergeRequest,createdAt,headRefOid,body,statusCheckRollup)

# One line per candidate, oldest first: number, head SHA, ci state, ticked.
# The ci state is the conclusion when the check completed, else its status
# (QUEUED, IN_PROGRESS, ...), MISSING when there is no `ci` check yet.
rows=$(jq -r --arg ticked "$TICKED" '
  [.[] | select(.isDraft | not) | select(.autoMergeRequest != null)]
  | sort_by(.createdAt)[]
  | [ .number, .headRefOid,
      ([.statusCheckRollup[]? | select(.name == "ci")] | last
        | if . == null then "MISSING"
          elif (.conclusion // "") != "" then .conclusion
          else .status // "MISSING" end),
      ((.body // "") | contains($ticked)) ]
  | @tsv' <<<"$prs")

if [ -z "$rows" ]; then
  echo "no Renovate pull request with auto-merge open"
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
