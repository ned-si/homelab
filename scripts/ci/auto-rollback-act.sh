#!/bin/bash
# auto-rollback-act.sh -- carry out a decision of auto-rollback-decide.sh.
#
# ACTION=revert:
#   1. a commit on top of SHA whose tree is REVERT_TREE (the tree of SHA's
#      parent), created through the Git Data API with BOT_TOKEN (GITHUB_TOKEN)
#      and no author, so GitHub signs it and the `commits` check passes;
#   2. branch auto-revert/<sha12> pointing at it. If the branch already exists
#      another run handled this commit: no second pull request;
#   3. a pull request titled PR_TITLE with label `auto-rollback`, opened with
#      PR_TOKEN, and auto-merge (squash) on it. PR_TOKEN is a fine-grained
#      token of the repository owner: GitHub Actions may not open pull requests
#      with GITHUB_TOKEN in this repository, and a pull request opened by
#      GITHUB_TOKEN would not start CI, so auto-merge would wait forever.
# The pull request is the record of the rollback. No issue is opened: the
# failure is an alert (Alertmanager -> ntfy) that resolves on its own.
#
# Any other ACTION is a no-op that prints the reason.
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

if [ "$ACTION" != revert ]; then
  echo "auto-rollback-act: $ACTION for $APP, nothing to do ($REASON)"
  exit 0
fi

[ -n "${PR_TOKEN:-}" ] || die "the AUTO_ROLLBACK_TOKEN secret is not set; see platform/secrets/argocd-notifications.sops.yaml.example"
[[ "$APP" =~ ^[a-z0-9-]+$ ]] || die "invalid app name"
: "${BOT_TOKEN:?}" "${PR_TITLE:?}" "${REVERT_TREE:?}"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "bad SHA"
[[ "$REVERT_TREE" =~ ^[0-9a-f]{40}$ ]] || die "bad REVERT_TREE"

bot() { GH_TOKEN=$BOT_TOKEN gh "$@"; }
owner() { GH_TOKEN=$PR_TOKEN gh "$@"; }

branch="auto-revert/${SHA:0:12}"

message=$(printf '%s\n\nThis reverts commit %s.\n\nArgo CD reported %s for %s after this commit was deployed.\n' \
  "$PR_TITLE" "$SHA" "$TRIGGER" "$APP")
commit=$(jq -n --arg m "$message" --arg t "$REVERT_TREE" --arg p "$SHA" \
    '{message: $m, tree: $t, parents: [$p]}' \
  | bot api "repos/$REPO/git/commits" --input - --jq '.sha')
echo "auto-rollback-act: revert commit $commit"

if ! jq -n --arg r "refs/heads/$branch" --arg s "$commit" '{ref: $r, sha: $s}' \
    | bot api "repos/$REPO/git/refs" --input - >/dev/null 2>&1; then
  echo "auto-rollback-act: $branch already exists; no second pull request"
  exit 0
fi

body=$(printf 'Automatic revert of %s (`%s`).\n\nArgo CD reported `%s` for `%s` after it was deployed. Auto-merge is on: this merges once CI is green.\n\n- Application: https://argo.lilalala.com/applications/argo/%s\n- Decision: %s.\n' \
  "$SHA" "$SUBJECT" "$TRIGGER" "$APP" "$APP" "$REASON")
[ -n "$RUN_URL" ] && body=$(printf '%s\n- Workflow run: %s\n' "$body" "$RUN_URL")
if [ "$STATEFUL" = true ]; then
  body=$(printf '%s\n\n`%s` keeps state in a database. Reverting the image does not undo a schema migration the new version may already have run: if the app still fails after the revert, restore its database from the latest backup (docs/backups.md).\n' \
    "$body" "$APP")
fi
pr=$(jq -n --arg t "$PR_TITLE" --arg h "$branch" --arg b "$body" \
    '{title: $t, head: $h, base: "main", body: $b}' \
  | owner api "repos/$REPO/pulls" --input - --jq '.number')
# The label is for finding these later; a failure to set it must not stop the
# revert from merging.
jq -n '{labels: ["auto-rollback"]}' \
  | owner api "repos/$REPO/issues/$pr/labels" --input - >/dev/null ||
  echo "::warning::auto-rollback-act: could not label #$pr"
owner pr merge "$pr" --repo "$REPO" --auto --squash
echo "auto-rollback-act: pull request #$pr, auto-merge on"
