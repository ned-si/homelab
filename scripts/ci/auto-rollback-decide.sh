#!/bin/bash
# auto-rollback-decide.sh -- decide what to do about an Argo CD failure report.
#
# Argo CD Notifications sends a `repository_dispatch` (event type
# `argo-degraded`) when an Application's sync fails or its health turns
# Degraded (bootstrap/argocd-values.yaml). .github/workflows/auto-rollback.yaml
# runs this script on a full checkout of main. It picks one action:
#
#   revert  an auto-merged revert pull request, plus an issue
#   issue   an issue only (or a comment on the open issue for that app)
#
# A revert needs every guard rail to pass:
#   1. REVISION names a commit on main, and it is the newest commit on main:
#      a later merge may already have changed or fixed the app, and the revert
#      is built as "main with the tree of that commit's parent";
#   2. that commit landed less than MAX_AGE seconds ago (default 1 h);
#   3. the app is not in NO_REVERT_APPS (default: cilium democratic-csi). A
#      revert of the CNI or the CSI driver is itself a risky deploy that can
#      take the network or every volume down, so a person decides;
#   4. no two automatic reverts in a row: the commit is not itself a revert,
#      and the commit before it is not an automatic revert (subject ending in
#      `(auto)`) from the last LOOP_WINDOW seconds (default 24 h);
#   5. the commit changed a file of that app: a path segment `<app>/`, a file
#      `<app>.yaml` or `application-<app>.yaml`, and `<layer>/secrets/` for
#      `secrets-<layer>`. So the failure is pinned on the merge that deployed
#      it, not on whatever merged last.
# Anything else is an issue, with the reason. Apps in STATEFUL_APPS get a note
# that a revert does not undo a schema migration.
#
# Environment: APP, TRIGGER (on-sync-failed | on-health-degraded), REVISION
# (tokens separated by spaces or commas; only 40-hex SHAs of this repository
# count, chart versions are ignored), DRY_RUN (true = report only), MAIN_REF
# (default origin/main), NOW (epoch seconds, default now), MAX_AGE,
# LOOP_WINDOW, NO_REVERT_APPS, STATEFUL_APPS.
# Writes key=value lines to $GITHUB_OUTPUT when set; prints a summary.
# Exit 0 with a decision, 1 on invalid input.
set -euo pipefail

APP=${APP:-}
TRIGGER=${TRIGGER:-}
REVISION=${REVISION:-}
DRY_RUN=${DRY_RUN:-false}
MAIN_REF=${MAIN_REF:-origin/main}
NOW=${NOW:-$(date +%s)}
MAX_AGE=${MAX_AGE:-3600}
LOOP_WINDOW=${LOOP_WINDOW:-86400}
NO_REVERT_APPS=${NO_REVERT_APPS:-cilium democratic-csi}
STATEFUL_APPS=${STATEFUL_APPS:-immich keycloak mealie paperless seafile theater}

die() { echo "auto-rollback-decide: $*" >&2; exit 1; }

# The payload is data from outside the workflow: accept only what an Argo CD
# Application name and the two triggers can be.
[[ "$APP" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid app name: '$APP'"
case "$TRIGGER" in
  on-sync-failed | on-health-degraded) ;;
  *) die "invalid trigger: '$TRIGGER'" ;;
esac
[ "$DRY_RUN" = true ] || DRY_RUN=false
# One line of revision-like characters, so nothing in it can add an output.
REVISION=$(printf '%s' "$REVISION" | tr -c 'A-Za-z0-9 ,._+-' ' ' | cut -c1-300)
main=$(git rev-parse --verify "$MAIN_REF^{commit}") || die "cannot resolve $MAIN_REF"

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# Drop the " (#123)" suffixes squash merges add, so a revert of a revert does
# not collect them.
strip_pr() { sed -E 's/( \(#[0-9]+\))+$//' <<<"$1"; }

# Does any of the files (one per line on stdin) belong to the app?
touches_app() {
  local app=$1 layer="" f base
  case "$app" in secrets-*) layer=${app#secrets-} ;; esac
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=${f##*/}
    case "/$f" in */"$app"/*) return 0 ;; esac
    [ "$base" = "$app.yaml" ] && return 0
    [ "$base" = "application-$app.yaml" ] && return 0
    if [ -n "$layer" ]; then
      case "$f" in "$layer/secrets/"*) return 0 ;; esac
    fi
  done
  return 1
}

sha=""
for tok in $(tr ',' ' ' <<<"$REVISION"); do
  [[ "$tok" =~ ^[0-9a-f]{40}$ ]] || continue
  git cat-file -e "$tok^{commit}" 2>/dev/null || continue
  git merge-base --is-ancestor "$tok" "$main" || continue
  sha=$tok
  break
done

action=issue reason="" subject="" pr_title="" revert_tree=""
stateful=false
in_list "$APP" "$STATEFUL_APPS" && stateful=true

if [ -z "$sha" ]; then
  reason="the revision '$REVISION' names no commit on main"
else
  subject=$(strip_pr "$(git log -1 --format=%s "$sha")")
  committed=$(git log -1 --format=%ct "$sha")
  age=$((NOW - committed))
  prev_subject="" prev_age=""
  if git rev-parse --verify -q "$sha^" >/dev/null; then
    prev_subject=$(strip_pr "$(git log -1 --format=%s "$sha^")")
    prev_age=$((NOW - $(git log -1 --format=%ct "$sha^")))
    revert_tree=$(git rev-parse "$sha^^{tree}")
  fi
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$subject")

  if [ -z "$revert_tree" ]; then
    reason="the commit has no parent to revert to"
  elif [ "$sha" != "$main" ]; then
    reason="not the newest commit on main (main is at ${main:0:12})"
  elif [ "$age" -ge "$MAX_AGE" ]; then
    reason="merged ${age}s ago, the limit is ${MAX_AGE}s"
  elif in_list "$APP" "$NO_REVERT_APPS"; then
    reason="$APP is never reverted automatically"
  elif [[ "$lower" == revert* ]]; then
    reason="the commit is itself a revert"
  elif [[ "$prev_subject" == *"(auto)" ]] && [ "$prev_age" -lt "$LOOP_WINDOW" ]; then
    reason="the previous commit is an automatic revert; never two in a row"
  elif ! git diff-tree --no-commit-id --name-only -r "$sha" | touches_app "$APP"; then
    reason="the commit changes no file of $APP"
  else
    action=revert
    reason="newest commit on main, merged ${age}s ago, changes $APP"
    # `revert: <subject> (auto)`, the subject cut to 53 characters: the
    # longest title scripts/ci/check-title.sh accepts for type `revert`
    # is 68.
    inner=$(sed -E 's/[ .]+$//' <<<"${subject:0:53}")
    pr_title="revert: $inner (auto)"
  fi
fi

echo "app=$APP trigger=$TRIGGER dry_run=$DRY_RUN"
echo "revision=${sha:-none} subject=${subject:-n/a}"
echo "decision: $action ($reason)"
[ -n "$pr_title" ] && echo "revert pull request: $pr_title"
[ "$DRY_RUN" = true ] && echo "dry run: nothing is created"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "action=$action"
    echo "reason=$reason"
    echo "app=$APP"
    echo "trigger=$TRIGGER"
    echo "sha=$sha"
    echo "subject=$subject"
    echo "pr_title=$pr_title"
    echo "revert_tree=$revert_tree"
    echo "stateful=$stateful"
    echo "dry_run=$DRY_RUN"
  } >> "$GITHUB_OUTPUT"
fi
