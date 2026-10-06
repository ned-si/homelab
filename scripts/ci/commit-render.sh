#!/bin/bash
# commit-render.sh -- commit the re-rendered deploy/ to a pull request branch
# through the GitHub REST API, then approve the pull_request runs it triggers.
#
# Run from the checkout scripts/render-deploy.sh just rendered. Does nothing
# when deploy/ is already up to date.
#
# Why the API and not `git push`: a commit created through the Git Data API
# with GITHUB_TOKEN and no author or committer is signed by GitHub as
# github-actions[bot], so it is verified, which branch protection and the
# `commits` check require.
#
# The ref update is not forced: it fails if the branch moved past HEAD_SHA,
# and the push that moved it runs the render again.
#
# Environment: GH_TOKEN (contents: write, actions: write), REPO (owner/name),
# BRANCH (head branch), HEAD_SHA (the commit that was rendered). APPROVE_TRIES
# and APPROVE_DELAY (seconds) bound the wait for the runs (default 24 x 5 s).
set -euo pipefail

: "${REPO:?REPO not set}" "${BRANCH:?BRANCH not set}" "${HEAD_SHA:?HEAD_SHA not set}"
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "commit-render: bad HEAD_SHA" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$HEAD_SHA" ] || { echo "commit-render: checkout is not $HEAD_SHA" >&2; exit 1; }

git add -A -- deploy
changes=$(git diff --cached --name-status --no-renames -- deploy)
if [ -z "$changes" ]; then
  echo "commit-render: deploy/ is up to date"
  exit 0
fi
echo "commit-render: $(wc -l <<<"$changes" | tr -d ' ') file(s) changed under deploy/"

entries='[]'
while IFS=$'\t' read -r status path; do
  if [ "$status" = "D" ]; then
    entry=$(jq -n --arg p "$path" '{path: $p, mode: "100644", type: "blob", sha: null}')
  else
    blob=$(base64 < "$path" | tr -d '\n' \
      | jq -Rs '{content: ., encoding: "base64"}' \
      | gh api "repos/$REPO/git/blobs" --input - --jq '.sha')
    mode=100644
    [ -x "$path" ] && mode=100755
    entry=$(jq -n --arg p "$path" --arg m "$mode" --arg s "$blob" '{path: $p, mode: $m, type: "blob", sha: $s}')
  fi
  entries=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$entries")
done <<<"$changes"

base_tree=$(gh api "repos/$REPO/git/commits/$HEAD_SHA" --jq '.tree.sha')
tree=$(jq -n --arg b "$base_tree" --argjson t "$entries" '{base_tree: $b, tree: $t}' \
  | gh api "repos/$REPO/git/trees" --input - --jq '.sha')
commit=$(jq -n --arg t "$tree" --arg p "$HEAD_SHA" \
    '{message: "chore(deploy): re-render deploy/", tree: $t, parents: [$p]}' \
  | gh api "repos/$REPO/git/commits" --input - --jq '.sha')
jq -n --arg s "$commit" '{sha: $s, force: false}' \
  | gh api -X PATCH "repos/$REPO/git/refs/heads/$BRANCH" --input - >/dev/null
echo "commit-render: $BRANCH -> $commit"

# The ref update fires `pull_request: synchronize` as github-actions[bot],
# which the repository's approval policy treats as a first-time contributor:
# the runs are created as `action_required` and, until approved, the PR shows
# no checks at all. Approve every run on the new head, and wait until both
# workflows have one: ci (the required check) and this render, which finds
# deploy/ up to date and exits.
tries=${APPROVE_TRIES:-24}
delay=${APPROVE_DELAY:-5}
for i in $(seq 1 "$tries"); do
  runs=$(gh api "repos/$REPO/actions/runs?head_sha=$commit&event=pull_request&per_page=100" \
    --jq '.workflow_runs[] | [(.id | tostring), .path, (.conclusion // "")] | @tsv')
  seen=""
  while IFS=$'\t' read -r id path conclusion; do
    [ -n "$id" ] || continue
    seen="$seen $path"
    if [ "$conclusion" = "action_required" ]; then
      gh api -X POST "repos/$REPO/actions/runs/$id/approve" >/dev/null
      echo "commit-render: approved run $id ($path)"
    fi
  done <<<"$runs"
  case "$seen" in
    *.github/workflows/ci.yaml*)
      case "$seen" in
        *.github/workflows/renovate-render.yaml*)
          echo "commit-render: ci and renovate-render run on $commit"
          exit 0 ;;
      esac ;;
  esac
  [ "$i" -lt "$tries" ] && sleep "$delay"
done
echo "::error::commit-render: runs for $commit did not all appear; approve them in the Actions tab" >&2
exit 1
