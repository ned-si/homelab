#!/bin/bash
# pr-merge.sh [--dry-run] [--ff] <pr-number>
#
# The only way code lands on `main` while branch protection is unavailable
# (private repository on GitHub Free, see the governance ADR). It refuses
# (exit 2, one line per failed guard) unless every guard holds:
#
#   checks         every required check reports SUCCESS for the PR head SHA
#   title          the PR title passes scripts/ci/check-title.sh
#   subjects       every commit subject passes scripts/ci/check-title.sh
#   verified       every commit is signed and verified by GitHub
#   up-to-date     origin/main is an ancestor of the PR head
#   mergeable      the PR is open, not a draft, targets main, and is MERGEABLE
#   merge-freeze   gh_var_state MERGE_FREEZE prints `absent`; `present` prints
#                  the variable's value as the reason, `error` refuses with
#                  "variables API unavailable" (fail closed)
#   ff-protected   (--ff only) main has no branch protection (HTTP 200 on the
#                  protection endpoint refuses; 403/404 = none)
#
# Then it squash-merges (`gh pr merge --squash --delete-branch
# --match-head-commit <sha>`), or with --ff pushes the verified head SHA to main
# as a fast-forward (`git push origin <sha>:refs/heads/main`, which the server
# rejects if it is not one). --dry-run prints the decision and changes nothing:
# "would merge (<mode>) PR #<n> at <sha>" on exit 0.
#
# Exit codes: 0 merged / would merge, 2 refused, 1 operational error, 64 usage.
# Environment: GH_VAR_REPO / PR_MERGE_REPO (default ned-si/homelab),
# PR_MERGE_REMOTE (default origin).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/gh_var.sh
. "$HERE/lib/gh_var.sh"
CHECK_TITLE="$HERE/ci/check-title.sh"

REPO=${PR_MERGE_REPO:-${GH_VAR_REPO:-ned-si/homelab}}
export GH_VAR_REPO=$REPO
REMOTE=${PR_MERGE_REMOTE:-origin}
REQUIRED_CHECKS="yamllint actionlint shellcheck render repo-policy kubeconform gitleaks trivy tofu pr-title commits ci"

dry_run=0
mode=squash
pr=""
usage() { echo "usage: $0 [--dry-run] [--ff] <pr-number>" >&2; exit 64; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --ff) mode=ff ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$pr" ] || usage; pr=$1 ;;
  esac
  shift
done
[[ "$pr" =~ ^[0-9]+$ ]] || usage

refusals=0
refuse() { # guard reason
  echo "refused: $1: $2"
  refusals=$((refusals + 1))
}
log() { echo "pr-merge: $*"; }

status_of() { # <gh api --include output> -> status or empty
  local first
  first=$(printf '%s\n' "$1" | head -n 1 | tr -d '\r')
  if [[ "$first" =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

# --- PR metadata ------------------------------------------------------------
if ! view=$(gh pr view "$pr" --repo "$REPO" \
      --json number,title,state,isDraft,baseRefName,headRefName,headRefOid,mergeable 2>&1); then
  echo "pr-merge: cannot read PR #$pr" >&2
  exit 1
fi
title=$(jq -r '.title' <<<"$view")
head=$(jq -r '.headRefOid' <<<"$view")
log "PR #$pr ($mode) head $head: $title"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "pr-merge: bad head SHA" >&2; exit 1; }

# --- mergeable ----------------------------------------------------------------
state=$(jq -r '.state' <<<"$view")
draft=$(jq -r '.isDraft' <<<"$view")
base=$(jq -r '.baseRefName' <<<"$view")
mergeable=$(jq -r '.mergeable' <<<"$view")
[ "$state" = "OPEN" ] || refuse mergeable "state is $state"
[ "$draft" = "false" ] || refuse mergeable "PR is a draft"
[ "$base" = "main" ] || refuse mergeable "base is $base, not main"
[ "$mergeable" = "MERGEABLE" ] || refuse mergeable "GitHub reports $mergeable"

# --- checks -------------------------------------------------------------------
if checks=$(gh pr checks "$pr" --repo "$REPO" --json name,state,startedAt,link 2>/dev/null) \
   || [ -n "${checks:-}" ]; then
  for c in $REQUIRED_CHECKS; do
    # The most recent run of each check name decides (older cancelled runs of
    # the same SHA are superseded).
    st=$(jq -r --arg n "$c" '[.[] | select(.name == $n)] | sort_by(.startedAt // "") | last | .state // "MISSING"' <<<"$checks" 2>/dev/null || echo MISSING)
    [ "$st" = "SUCCESS" ] || refuse checks "$c is $st"
  done
else
  refuse checks "cannot read the PR checks"
fi

# --- title and subjects -------------------------------------------------------
if ! reason=$("$CHECK_TITLE" "$title" 2>&1); then
  refuse title "$reason"
fi
if commits=$(gh api --paginate "repos/$REPO/pulls/$pr/commits" 2>/dev/null); then
  n=$(jq -s 'add | length' <<<"$commits")
  [ "$n" -gt 0 ] || refuse subjects "PR has no commits"
  while IFS=$'\t' read -r sha verified subject; do
    [ -n "$sha" ] || continue
    if ! reason=$("$CHECK_TITLE" "$subject" 2>&1); then
      refuse subjects "${sha:0:7} $reason"
    fi
    [ "$verified" = "true" ] || refuse verified "${sha:0:7} is not a verified signed commit"
  done < <(jq -rs 'add | .[] | [.sha, (.commit.verification.verified | tostring), (.commit.message | split("\n")[0])] | @tsv' <<<"$commits")
else
  refuse subjects "cannot read the PR commits"
fi

# --- up-to-date -----------------------------------------------------------------
if git fetch --quiet "$REMOTE" main "$head" 2>/dev/null; then
  main_sha=$(git rev-parse "refs/remotes/$REMOTE/main" 2>/dev/null || true)
  if [ -z "$main_sha" ] || ! git merge-base --is-ancestor "$main_sha" "$head" 2>/dev/null; then
    refuse up-to-date "head does not contain $REMOTE/main ${main_sha:0:7}; rebase first"
  fi
else
  refuse up-to-date "cannot fetch $REMOTE main and the head commit"
fi

# --- merge-freeze -----------------------------------------------------------------
case "$(gh_var_state MERGE_FREEZE)" in
  absent) ;;
  present)
    val=$(gh api "repos/$REPO/actions/variables/MERGE_FREEZE" --jq '.value' 2>/dev/null || echo "?")
    refuse merge-freeze "MERGE_FREEZE is set: ${val:0:200}" ;;
  *) refuse merge-freeze "variables API unavailable" ;;
esac

# --- ff-protected -----------------------------------------------------------------
if [ "$mode" = "ff" ]; then
  out=$(gh api --include "repos/$REPO/branches/main/protection" 2>&1) || true
  st=$(status_of "$out")
  case "$st" in
    200) refuse ff-protected "main is protected; a direct fast-forward push would be rejected (use squash)" ;;
    403|404) ;;
    *) refuse ff-protected "cannot determine branch protection (status '${st:-none}')" ;;
  esac
fi

# --- decision -----------------------------------------------------------------------
if [ "$refusals" -gt 0 ]; then
  log "REFUSED PR #$pr ($refusals guard failure(s)); nothing merged"
  exit 2
fi
if [ "$dry_run" -eq 1 ]; then
  echo "would merge ($mode) PR #$pr at $head"
  exit 0
fi
if [ "$mode" = "ff" ]; then
  log "fast-forwarding main to $head"
  git push "$REMOTE" "$head:refs/heads/main"
else
  log "squash-merging PR #$pr at $head"
  gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --match-head-commit "$head"
fi
log "merged PR #$pr ($mode)"
