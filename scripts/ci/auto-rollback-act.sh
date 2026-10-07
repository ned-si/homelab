#!/bin/bash
# auto-rollback-act.sh -- carry out a decision of auto-rollback-decide.sh.
#
# ACTION=revert:
#   1. a commit on top of SHA whose tree is REVERT_TREE (the tree of SHA's
#      parent), created through the Git Data API with BOT_TOKEN (GITHUB_TOKEN)
#      and no author, so GitHub signs it and the `commits` check passes;
#   2. branch auto-revert/<sha12> pointing at it. If the branch already exists
#      another run handled this commit: no second pull request;
#   3. a pull request titled PR_TITLE, opened with PR_TOKEN, and auto-merge
#      (squash) on it. PR_TOKEN is a fine-grained token of the repository
#      owner: GitHub Actions may not open pull requests with GITHUB_TOKEN in
#      this repository, and a pull request opened by GITHUB_TOKEN would not
#      start CI, so auto-merge would wait forever.
# Then, for both actions, an issue "Argo CD: <app> failed after a deploy",
# or a comment on the open one, so one broken app is one issue.
#
# Environment: ACTION, APP, TRIGGER, SHA, SUBJECT, PR_TITLE, REVERT_TREE,
# REASON, STATEFUL, REPO (owner/name), BOT_TOKEN, PR_TOKEN, RUN_URL.
#
# The backticks in the printf formats below are Markdown code spans.
# shellcheck disable=SC2016
set -euo pipefail

: "${ACTION:?}" "${APP:?}" "${TRIGGER:?}" "${REPO:?}" "${REASON:?}"
SHA=${SHA:-}
SUBJECT=${SUBJECT:-}
STATEFUL=${STATEFUL:-false}
RUN_URL=${RUN_URL:-}

die() { echo "::error::auto-rollback-act: $*" >&2; exit 1; }

[ -n "${PR_TOKEN:-}" ] || die "the AUTO_ROLLBACK_TOKEN secret is not set; see platform/secrets/argocd-notifications.sops.yaml.example"
[[ "$APP" =~ ^[a-z0-9-]+$ ]] || die "invalid app name"

bot() { GH_TOKEN=$BOT_TOKEN gh "$@"; }
owner() { GH_TOKEN=$PR_TOKEN gh "$@"; }

pr_line=""
if [ "$ACTION" = revert ]; then
  : "${BOT_TOKEN:?}" "${PR_TITLE:?}" "${REVERT_TREE:?}"
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "bad SHA"
  [[ "$REVERT_TREE" =~ ^[0-9a-f]{40}$ ]] || die "bad REVERT_TREE"
  branch="auto-revert/${SHA:0:12}"

  message=$(printf '%s\n\nThis reverts commit %s.\n\nArgo CD reported %s for %s after this commit was deployed.\n' \
    "$PR_TITLE" "$SHA" "$TRIGGER" "$APP")
  commit=$(jq -n --arg m "$message" --arg t "$REVERT_TREE" --arg p "$SHA" \
      '{message: $m, tree: $t, parents: [$p]}' \
    | bot api "repos/$REPO/git/commits" --input - --jq '.sha')
  echo "auto-rollback-act: revert commit $commit"

  if jq -n --arg r "refs/heads/$branch" --arg s "$commit" '{ref: $r, sha: $s}' \
      | bot api "repos/$REPO/git/refs" --input - >/dev/null 2>&1; then
    body=$(printf 'Automatic revert of %s (`%s`).\n\nArgo CD reported `%s` for `%s` after it was deployed. Auto-merge is on: this merges once CI is green.\n\nDecision: %s.\n' \
      "$SHA" "$SUBJECT" "$TRIGGER" "$APP" "$REASON")
    [ -n "$RUN_URL" ] && body=$(printf '%s\n\nWorkflow run: %s\n' "$body" "$RUN_URL")
    pr=$(jq -n --arg t "$PR_TITLE" --arg h "$branch" --arg b "$body" \
        '{title: $t, head: $h, base: "main", body: $b}' \
      | owner api "repos/$REPO/pulls" --input - --jq '.number')
    owner pr merge "$pr" --repo "$REPO" --auto --squash
    echo "auto-rollback-act: pull request #$pr, auto-merge on"
    pr_line="- Revert pull request: #$pr (auto-merge on green CI)"
  else
    echo "auto-rollback-act: $branch already exists; no second pull request"
    pr_line="- Revert: branch \`$branch\` already existed, no second pull request"
  fi
fi

if [ -n "$SHA" ]; then
  commit_line="- Commit: https://github.com/$REPO/commit/$SHA ($SUBJECT)"
else
  commit_line="- Commit: none identified"
fi
if [ "$ACTION" = revert ]; then
  decision="reverted automatically"
else
  decision="not reverted, needs a person"
fi
body=$(printf 'Argo CD reported `%s` for `%s`.\n\n%s\n- Application: https://argo.lilalala.com/applications/argo/%s\n- Decision: %s: %s\n' \
  "$TRIGGER" "$APP" "$commit_line" "$APP" "$decision" "$REASON")
[ -n "$pr_line" ] && body=$(printf '%s\n%s\n' "$body" "$pr_line")
[ -n "$RUN_URL" ] && body=$(printf '%s\n- Workflow run: %s\n' "$body" "$RUN_URL")
if [ "$STATEFUL" = true ]; then
  body=$(printf '%s\n\n`%s` keeps state in a database. Reverting the image does not undo a schema migration the new version may already have run: if the app still fails after the revert, restore its database from the latest backup (docs/backups.md).\n' \
    "$body" "$APP")
fi

title="Argo CD: $APP failed after a deploy"
existing=$(owner api "repos/$REPO/issues?state=open&per_page=100" \
  --jq "[.[] | select(.pull_request == null and .title == \"$title\")][0].number // empty")
if [ -n "$existing" ]; then
  jq -n --arg b "$body" '{body: $b}' \
    | owner api "repos/$REPO/issues/$existing/comments" --input - >/dev/null
  echo "auto-rollback-act: commented on issue #$existing"
else
  issue=$(jq -n --arg t "$title" --arg b "$body" '{title: $t, body: $b}' \
    | owner api "repos/$REPO/issues" --input - --jq '.number')
  echo "auto-rollback-act: opened issue #$issue"
fi
