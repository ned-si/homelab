#!/bin/bash
# commit-render.sh -- commit the re-rendered deploy/ to a pull request branch
# through the GitHub REST API, then dispatch ci.yaml on that branch.
#
# Run from the checkout scripts/render-deploy.sh just rendered. Does nothing
# when deploy/ is already up to date.
#
# Why the API and not `git push`: a commit created through the Git Data API
# with GITHUB_TOKEN and no author or committer is signed by GitHub as
# github-actions[bot], so it is verified, which branch protection and the
# `commits` check require. Pushes made with GITHUB_TOKEN start no workflows,
# hence the explicit dispatch of ci.yaml.
#
# The ref update is not forced: it fails if the branch moved past HEAD_SHA,
# and the push that moved it runs the render again.
#
# Environment: GH_TOKEN (contents: write, actions: write), REPO (owner/name),
# BRANCH (head branch), HEAD_SHA (the commit that was rendered).
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

gh workflow run ci.yaml --repo "$REPO" --ref "$BRANCH"
echo "commit-render: dispatched ci.yaml on $BRANCH"
